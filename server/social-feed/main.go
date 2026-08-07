package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

const maxJSONBodyBytes = 1 << 20

const updateBoatTypeSQL = `INSERT INTO skipper_profiles (id, name, boat_type)
	VALUES ($1, $2, $3)
	ON CONFLICT (id) DO UPDATE SET
		boat_type = EXCLUDED.boat_type,
		updated_at = now()`

type application struct {
	db                 *sql.DB
	storage            storageConfig
	localUploads       localUploadConfig
	identity           firebaseIdentityProvider
	pushSender         pushNotificationSender
	realtime           *realtimeHub
	pushWake           chan struct{}
	publicBaseURL      string
	uploadPublicOrigin *url.URL
	production         bool
	allowInsecureHTTP  bool
	configurationError string
}

type storageConfig struct {
	enabled     bool
	endpoint    *url.URL
	region      string
	bucket      string
	accessKeyID string
	secretKey   string
	publicBase  string
	presignTTL  time.Duration
}

type localUploadConfig struct {
	enabled    bool
	directory  string
	publicBase string
	signingKey []byte
	presignTTL time.Duration
}

type createPostRequest struct {
	SkipperID              string  `json:"skipper_id"`
	SkipperName            string  `json:"skipper_name"`
	SkipperProfileImageURL *string `json:"skipper_profile_image_url"`
	Text                   string  `json:"text"`
	ImageURL               *string `json:"image_url"`
}

type likePostRequest struct {
	SkipperID string `json:"skipper_id"`
}

type updateProfileRequest struct {
	SkipperID       string  `json:"skipper_id"`
	Name            string  `json:"name"`
	BoatType        string  `json:"boat_type"`
	HomeHarbour     *string `json:"home_harbour"`
	Bio             *string `json:"bio"`
	ProfileImageURL *string `json:"profile_image_url"`
}

type updateBoatTypeRequest struct {
	BoatType string `json:"boat_type"`
}

type createCommentRequest struct {
	SkipperID   string `json:"skipper_id"`
	SkipperName string `json:"skipper_name"`
	Text        string `json:"text"`
}

type presignUploadRequest struct {
	ContentType   string `json:"content_type"`
	FileExtension string `json:"file_extension"`
}

type postResponse struct {
	ID                     string           `json:"id"`
	SkipperID              string           `json:"skipper_id"`
	SkipperName            string           `json:"skipper_name"`
	SkipperProfileImageURL *string          `json:"skipper_profile_image_url"`
	Text                   string           `json:"text"`
	ImageURL               *string          `json:"image_url"`
	LikedBySkipperIDs      []string         `json:"liked_by_skipper_ids"`
	CommentIDs             []string         `json:"comment_ids"`
	LikeCount              int              `json:"like_count"`
	CommentCount           int              `json:"comment_count"`
	CreatedAt              time.Time        `json:"created_at"`
	UpdatedAt              time.Time        `json:"updated_at"`
	Profile                *profileResponse `json:"profile,omitempty"`
}

type profileResponse struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	BoatType        string   `json:"boat_type"`
	ProfileImageURL *string  `json:"profile_image_url"`
	HomeHarbour     *string  `json:"home_harbour"`
	Bio             *string  `json:"bio"`
	PostIDs         []string `json:"post_ids"`
	FollowerCount   int      `json:"follower_count"`
	FollowingCount  int      `json:"following_count"`
	IsFollowed      bool     `json:"is_followed_by_current_skipper"`
}

type commentResponse struct {
	ID          string    `json:"id"`
	PostID      string    `json:"post_id"`
	SkipperID   string    `json:"skipper_id"`
	SkipperName string    `json:"skipper_name"`
	Text        string    `json:"text"`
	CreatedAt   time.Time `json:"created_at"`
}

type createCommentResponse struct {
	Post    postResponse    `json:"post"`
	Comment commentResponse `json:"comment"`
}

type presignUploadResponse struct {
	UploadURL string            `json:"upload_url"`
	PublicURL string            `json:"public_url"`
	Method    string            `json:"method"`
	Headers   map[string]string `json:"headers"`
}

type errorResponse struct {
	Error string `json:"error"`
}

type dbRunner interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func main() {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		slog.Error("DATABASE_URL is required")
		os.Exit(1)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		slog.Error("open database", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(1)
	db.SetConnMaxIdleTime(2 * time.Minute)
	db.SetConnMaxLifetime(30 * time.Minute)

	startupContext, startupCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer startupCancel()
	if err := db.PingContext(startupContext); err != nil {
		slog.Error("connect database", "error", err)
		os.Exit(1)
	}

	production := isProductionEnvironment()
	allowInsecureHTTP := !production && explicitlyEnabled(os.Getenv("ALLOW_INSECURE_LOCAL_HTTP"))
	firebaseProjectID := strings.TrimSpace(os.Getenv("FIREBASE_PROJECT_ID"))
	if production && firebaseProjectID == "" {
		slog.Error("FIREBASE_PROJECT_ID is required in production")
		os.Exit(1)
	}
	var firebaseAdmin *firebaseAdminClient
	if firebaseProjectID != "" {
		firebaseAdmin, err = newFirebaseAdminClient(startupContext, firebaseProjectID)
		if err != nil {
			slog.Error("initialize firebase admin", "error", err)
			os.Exit(1)
		}
	} else {
		slog.Warn("Firebase Admin is not configured; readiness will fail")
	}
	storage := loadStorageConfig()
	localUploads := loadLocalUploadConfig()
	publicBaseURL := strings.TrimRight(strings.TrimSpace(os.Getenv("PUBLIC_BASE_URL")), "/")
	uploadPublicOrigin := configuredUploadOrigin(
		os.Getenv("UPLOAD_PUBLIC_ORIGIN"),
		storage.publicBase,
		localUploads.publicBase,
	)
	configurationError := crewspaceRuntimeConfigurationError(
		publicBaseURL,
		uploadPublicOrigin,
		production,
		allowInsecureHTTP,
	)
	if configurationError == nil && localUploads.enabled {
		if err := validateCrewspacePublicURL(localUploads.publicBase, allowInsecureHTTP); err != nil {
			configurationError = fmt.Errorf("LOCAL_UPLOAD_PUBLIC_BASE_URL: %w", err)
		}
	}
	if configurationError == nil && storage.enabled {
		if err := validateCrewspacePublicURL(storage.publicBase, allowInsecureHTTP); err != nil {
			configurationError = fmt.Errorf("S3_PUBLIC_BASE_URL: %w", err)
		}
	}
	if configurationError != nil && production {
		slog.Error("invalid production Crewspace configuration", "error", configurationError)
		os.Exit(1)
	}
	app := &application{
		db:                 db,
		storage:            storage,
		localUploads:       localUploads,
		realtime:           newRealtimeHub(),
		pushWake:           make(chan struct{}, 1),
		publicBaseURL:      publicBaseURL,
		uploadPublicOrigin: uploadPublicOrigin,
		production:         production,
		allowInsecureHTTP:  allowInsecureHTTP,
	}
	if firebaseAdmin != nil {
		app.identity = firebaseAdmin
		app.pushSender = firebaseAdmin
	}
	if configurationError != nil {
		app.configurationError = configurationError.Error()
		slog.Warn("Crewspace readiness check will fail", "error", configurationError)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", app.handleHealth)
	mux.HandleFunc("GET /posts", app.handleListPosts)
	mux.HandleFunc("POST /posts", app.handleCreatePost)
	mux.HandleFunc("GET /posts/", app.handlePostRoutes)
	mux.HandleFunc("POST /posts/", app.handlePostRoutes)
	mux.HandleFunc("DELETE /posts/", app.handlePostRoutes)
	mux.HandleFunc("GET /profiles/", app.handleProfileRoutes)
	mux.HandleFunc("PUT /profiles/", app.handleProfileRoutes)
	mux.HandleFunc("PATCH /profiles/", app.handleProfileRoutes)
	mux.HandleFunc("POST /profiles/", app.handleProfileRoutes)
	mux.HandleFunc("POST /uploads/presign", app.handlePresignUpload)
	mux.HandleFunc("PUT /uploads/local/", app.handleLocalUpload)
	mux.HandleFunc("GET /uploads/local/", app.handleLocalUploadDownload)
	mux.HandleFunc("GET /crewspace/skippers/", app.handleCrewspaceSkipper)
	mux.HandleFunc("PUT /crewspace/me", app.handleUpdateCrewspaceMe)
	mux.HandleFunc("PUT /crewspace/devices", app.handlePutCrewspaceDevice)
	mux.HandleFunc("DELETE /crewspace/devices", app.handleDeleteCrewspaceDevice)
	mux.HandleFunc("DELETE /crewspace/devices/", app.handleDeleteCrewspaceDevice)
	mux.HandleFunc("GET /crewspace/blocks", app.handleListCrewspaceBlocks)
	mux.HandleFunc("PUT /crewspace/blocks/", app.handleCrewspaceBlockRoute)
	mux.HandleFunc("DELETE /crewspace/blocks/", app.handleCrewspaceBlockRoute)
	mux.HandleFunc("GET /crewspace/realtime", app.handleCrewspaceRealtime)
	mux.HandleFunc("GET /crewspace/conversations", app.handleListCrewspaceConversations)
	mux.HandleFunc("POST /crewspace/conversations", app.handleCreateCrewspaceGroup)
	mux.HandleFunc("POST /crewspace/direct", app.handleCreateCrewspaceDirect)
	mux.HandleFunc("POST /crewspace/uploads/presign", app.handleCrewspacePresignUpload)
	mux.HandleFunc("GET /crewspace/conversations/", app.handleCrewspaceConversationRoute)
	mux.HandleFunc("POST /crewspace/conversations/", app.handleCrewspaceConversationRoute)
	mux.HandleFunc("PUT /crewspace/conversations/", app.handleCrewspaceConversationRoute)
	mux.HandleFunc("GET /crewspace/events", app.handleListCrewspaceEvents)
	mux.HandleFunc("POST /crewspace/events", app.handleCreateCrewspaceEvent)
	mux.HandleFunc("POST /crewspace/events/", app.handleCrewspaceEventRoute)
	mux.HandleFunc("PUT /crewspace/events/", app.handleCrewspaceEventRoute)
	mux.HandleFunc("DELETE /crewspace/events/", app.handleCrewspaceEventRoute)
	mux.HandleFunc("DELETE /crewspace/conversations/", app.handleCrewspaceConversationRoute)
	mux.HandleFunc("POST /crewspace/polls/", app.handleCrewspacePollRoute)
	mux.HandleFunc("GET /maritime-notices", app.handleListMaritimeNotices)
	mux.HandleFunc("GET /maritime-notices/", app.handleMaritimeNoticeDetail)
	addr := envString("ADDR", ":8080")
	server := &http.Server{
		Addr:              addr,
		Handler:           commonHeaders(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      150 * time.Second,
		IdleTimeout:       150 * time.Second,
	}

	runContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	elwisConfig := loadELWISMailboxConfig()
	if elwisConfig.enabled {
		go app.runELWISMailbox(runContext, elwisConfig)
	}
	if app.pushSender != nil {
		go app.runPushOutbox(runContext)
	}

	slog.Info(
		"social feed server listening",
		"addr", addr,
		"storage_enabled", app.storage.enabled,
		"local_uploads_enabled", app.localUploads.enabled,
		"elwis_mailbox_enabled", elwisConfig.enabled,
		"public_base_url", app.publicBaseURL,
	)
	serverError := make(chan error, 1)
	go func() {
		serverError <- server.ListenAndServe()
	}()
	select {
	case err := <-serverError:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server stopped", "error", err)
			os.Exit(1)
		}
	case <-runContext.Done():
		app.realtime.shutdown()
		shutdownContext, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		if err := server.Shutdown(shutdownContext); err != nil {
			slog.Error("server shutdown", "error", err)
		}
	}
}

func (app *application) handleHealth(w http.ResponseWriter, _ *http.Request) {
	if app.identity == nil || app.pushSender == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "unhealthy",
			"error":  "firebase_not_configured",
		})
		return
	}
	if err := crewspaceRuntimeConfigurationError(
		app.publicBaseURL,
		app.uploadPublicOrigin,
		app.production,
		app.allowInsecureHTTP,
	); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "unhealthy",
			"error":  "crewspace_public_urls_invalid",
		})
		return
	}
	if app.configurationError != "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "unhealthy",
			"error":  "crewspace_configuration_invalid",
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func isProductionEnvironment() bool {
	for _, value := range []string{os.Getenv("APP_ENV"), os.Getenv("ENVIRONMENT")} {
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "prod", "production":
			return true
		}
	}
	return false
}

func explicitlyEnabled(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "1", "true", "yes":
		return true
	default:
		return false
	}
}

func crewspaceRuntimeConfigurationError(
	publicBaseURL string,
	uploadPublicOrigin *url.URL,
	production bool,
	allowInsecureHTTP bool,
) error {
	allowHTTP := !production && allowInsecureHTTP
	if err := validateCrewspacePublicURL(publicBaseURL, allowHTTP); err != nil {
		return fmt.Errorf("PUBLIC_BASE_URL: %w", err)
	}
	if uploadPublicOrigin == nil {
		return errors.New("UPLOAD_PUBLIC_ORIGIN is required")
	}
	if err := validateCrewspacePublicURL(uploadPublicOrigin.String(), allowHTTP); err != nil {
		return fmt.Errorf("UPLOAD_PUBLIC_ORIGIN: %w", err)
	}
	return nil
}

func validateCrewspacePublicURL(raw string, allowHTTP bool) error {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" {
		return errors.New("must be an absolute public URL")
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("must not contain credentials, a query, or a fragment")
	}
	if strings.EqualFold(parsed.Scheme, "https") {
		return nil
	}
	if allowHTTP && strings.EqualFold(parsed.Scheme, "http") {
		return nil
	}
	return errors.New("must use https")
}

func (app *application) handleListPosts(w http.ResponseWriter, r *http.Request) {
	skipperID := strings.TrimSpace(r.URL.Query().Get("skipperId"))
	posts, err := app.listPosts(r.Context(), skipperID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "posts konnten nicht geladen werden")
		slog.Error("list posts", "error", err)
		return
	}
	writeJSON(w, http.StatusOK, posts)
}

func (app *application) handleCreatePost(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input createPostRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	input.SkipperID = strings.TrimSpace(input.SkipperID)
	if input.SkipperID != "" && input.SkipperID != user.ID {
		writeError(w, http.StatusForbidden, "skipper_id stimmt nicht mit dem firebase-token ueberein")
		return
	}
	input.SkipperID = user.ID
	input.SkipperName = defaultName(user.Name)
	input.Text = strings.TrimSpace(input.Text)
	imageURL := cleanOptionalURL(input.ImageURL)
	profileImageURL := cleanOptionalURL(input.SkipperProfileImageURL)

	if input.Text == "" && imageURL == nil {
		writeError(w, http.StatusBadRequest, "text oder image_url ist erforderlich")
		return
	}
	if len(input.Text) > 2800 {
		writeError(w, http.StatusBadRequest, "text ist zu lang")
		return
	}
	if imageURL != nil && !isHTTPURL(*imageURL) {
		writeError(w, http.StatusBadRequest, "image_url muss eine HTTP(S)-URL sein")
		return
	}

	postID, err := newUUID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "id konnte nicht erzeugt werden")
		return
	}

	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()

	if err := upsertProfile(r.Context(), tx, input.SkipperID, input.SkipperName, profileImageURL); err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht gespeichert werden")
		return
	}

	_, err = tx.ExecContext(
		r.Context(),
		`INSERT INTO posts (id, skipper_id, text, image_url) VALUES ($1, $2, $3, $4)`,
		postID,
		input.SkipperID,
		input.Text,
		nullableArg(imageURL),
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht gespeichert werden")
		return
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht bestaetigt werden")
		return
	}

	post, err := app.getPost(r.Context(), postID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusCreated, post)
}

func (app *application) handlePostRoutes(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/posts/"), "/"), "/")
	if len(parts) == 1 && parts[0] != "" && r.Method == http.MethodDelete {
		app.handleDeletePost(w, r, parts[0])
		return
	}
	if len(parts) != 2 || parts[0] == "" {
		http.NotFound(w, r)
		return
	}

	postID := parts[0]
	switch {
	case r.Method == http.MethodPost && parts[1] == "like":
		app.handleLikePost(w, r, postID)
	case r.Method == http.MethodPost && parts[1] == "comment":
		app.handleCreateComment(w, r, postID)
	case r.Method == http.MethodGet && parts[1] == "comments":
		app.handleListComments(w, r, postID)
	default:
		http.NotFound(w, r)
	}
}

func (app *application) handleProfileRoutes(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/profiles/"), "/"), "/")
	if len(parts) == 1 && parts[0] != "" {
		switch r.Method {
		case http.MethodGet:
			app.handleGetProfile(w, r, parts[0])
		case http.MethodPut:
			app.handleUpdateProfile(w, r, parts[0])
		default:
			http.NotFound(w, r)
		}
		return
	}
	if len(parts) == 2 && parts[0] != "" &&
		(parts[1] == "follow" || parts[1] == "unfollow") &&
		r.Method == http.MethodPost {
		app.handleFollowMutation(w, r, parts[0], parts[1])
		return
	}
	if len(parts) == 2 && parts[0] != "" && parts[1] == "boat-type" && r.Method == http.MethodPatch {
		app.handleUpdateBoatType(w, r, parts[0])
		return
	}
	http.NotFound(w, r)
}

func (app *application) handleGetProfile(w http.ResponseWriter, r *http.Request, profileID string) {
	viewerID := strings.TrimSpace(r.URL.Query().Get("viewerId"))
	profile, err := app.getProfile(r.Context(), profileID, viewerID)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "profil nicht gefunden")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, profile)
}

func (app *application) handleUpdateProfile(w http.ResponseWriter, r *http.Request, profileID string) {
	user, ok := app.requireProfileOwner(w, r, profileID)
	if !ok {
		return
	}

	var input updateProfileRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	input.SkipperID = strings.TrimSpace(input.SkipperID)
	if input.SkipperID != "" && input.SkipperID != user.ID {
		writeError(w, http.StatusForbidden, "nur das eigene profil darf bearbeitet werden")
		return
	}
	input.SkipperID = user.ID
	input.Name = defaultName(input.Name)
	input.BoatType = strings.TrimSpace(input.BoatType)
	homeHarbour := cleanOptionalText(input.HomeHarbour, 80)
	bio := cleanOptionalText(input.Bio, 280)
	profileImageURL := cleanOptionalURL(input.ProfileImageURL)

	if input.BoatType == "" {
		input.BoatType = "Unbekannt"
	}
	if len(input.Name) > 80 {
		writeError(w, http.StatusBadRequest, "name ist zu lang")
		return
	}
	if len(input.BoatType) > 80 {
		writeError(w, http.StatusBadRequest, "bootstyp ist zu lang")
		return
	}
	if profileImageURL != nil && !isHTTPURL(*profileImageURL) {
		writeError(w, http.StatusBadRequest, "profile_image_url muss eine HTTP(S)-URL sein")
		return
	}

	_, err := app.db.ExecContext(
		r.Context(),
		`INSERT INTO skipper_profiles (id, name, boat_type, profile_image_url, home_harbour, bio)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name,
			boat_type = EXCLUDED.boat_type,
			profile_image_url = EXCLUDED.profile_image_url,
			home_harbour = EXCLUDED.home_harbour,
			bio = EXCLUDED.bio,
			updated_at = now()`,
		input.SkipperID,
		input.Name,
		input.BoatType,
		nullableArg(profileImageURL),
		nullableArg(homeHarbour),
		nullableArg(bio),
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht gespeichert werden")
		return
	}

	profile, err := app.getProfile(r.Context(), profileID, input.SkipperID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, profile)
}

func (app *application) handleUpdateBoatType(w http.ResponseWriter, r *http.Request, profileID string) {
	user, ok := app.requireProfileOwner(w, r, profileID)
	if !ok {
		return
	}

	var input updateBoatTypeRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	input.BoatType = strings.TrimSpace(input.BoatType)
	if input.BoatType == "" {
		input.BoatType = "Unbekannt"
	}
	if len(input.BoatType) > 80 {
		writeError(w, http.StatusBadRequest, "bootstyp ist zu lang")
		return
	}

	_, err := app.db.ExecContext(
		r.Context(),
		updateBoatTypeSQL,
		user.ID,
		defaultName(user.Name),
		input.BoatType,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "bootstyp konnte nicht gespeichert werden")
		return
	}

	profile, err := app.getProfile(r.Context(), profileID, user.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, profile)
}

func (app *application) requireProfileOwner(
	w http.ResponseWriter,
	r *http.Request,
	profileID string,
) (firebaseUser, bool) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return firebaseUser{}, false
	}
	if !profileBelongsToUser(profileID, user) {
		writeError(w, http.StatusForbidden, "nur das eigene profil darf bearbeitet werden")
		return firebaseUser{}, false
	}
	return user, true
}

func profileBelongsToUser(profileID string, user firebaseUser) bool {
	return strings.TrimSpace(profileID) != "" && strings.TrimSpace(profileID) == strings.TrimSpace(user.ID)
}

func (app *application) handleFollowMutation(
	w http.ResponseWriter,
	r *http.Request,
	profileID string,
	action string,
) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input likePostRequest
	bodyProvided := true
	if err := readJSON(w, r, &input); errors.Is(err, io.EOF) {
		bodyProvided = false
	} else if err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	input.SkipperID = strings.TrimSpace(input.SkipperID)
	if input.SkipperID != "" && input.SkipperID != user.ID {
		writeError(w, http.StatusForbidden, "skipper_id stimmt nicht mit dem firebase-token ueberein")
		return
	}
	input.SkipperID = user.ID
	if input.SkipperID == profileID {
		writeError(w, http.StatusBadRequest, "du kannst dir nicht selbst folgen")
		return
	}

	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()

	if err := upsertProfile(r.Context(), tx, user.ID, user.Name, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht gespeichert werden")
		return
	}
	targetExists, err := app.profileExistsTx(r.Context(), tx, profileID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht geprueft werden")
		return
	}
	if !targetExists {
		writeError(w, http.StatusNotFound, "profil nicht gefunden")
		return
	}

	switch {
	case action == "unfollow":
		if _, err := tx.ExecContext(
			r.Context(),
			`DELETE FROM profile_follows WHERE follower_id = $1 AND followed_id = $2`,
			user.ID,
			profileID,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "unfollow konnte nicht verarbeitet werden")
			return
		}
	case !bodyProvided:
		_, err = tx.ExecContext(
			r.Context(),
			`INSERT INTO profile_follows (follower_id, followed_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING`,
			user.ID,
			profileID,
		)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "follow konnte nicht gespeichert werden")
			return
		}
	default:
		var deleted int
		err = tx.QueryRowContext(
			r.Context(),
			`WITH removed AS (
				DELETE FROM profile_follows
				WHERE follower_id = $1 AND followed_id = $2
				RETURNING 1
			) SELECT count(*) FROM removed`,
			user.ID,
			profileID,
		).Scan(&deleted)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "follow konnte nicht verarbeitet werden")
			return
		}
		if deleted == 0 {
			if _, err := tx.ExecContext(
				r.Context(),
				`INSERT INTO profile_follows (follower_id, followed_id) VALUES ($1, $2)
				 ON CONFLICT DO NOTHING`,
				user.ID,
				profileID,
			); err != nil {
				writeError(w, http.StatusInternalServerError, "follow konnte nicht gespeichert werden")
				return
			}
		}
	}
	if err := app.refreshFollowCountsTx(r.Context(), tx, input.SkipperID, profileID); err != nil {
		writeError(w, http.StatusInternalServerError, "follow-zaehler konnten nicht aktualisiert werden")
		return
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "follow konnte nicht bestaetigt werden")
		return
	}

	profile, err := app.getProfile(r.Context(), profileID, input.SkipperID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, profile)
}

func (app *application) handleDeletePost(w http.ResponseWriter, r *http.Request, postID string) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input likePostRequest
	if err := readJSON(w, r, &input); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	input.SkipperID = strings.TrimSpace(input.SkipperID)
	if input.SkipperID != "" && input.SkipperID != user.ID {
		writeError(w, http.StatusForbidden, "skipper_id stimmt nicht mit dem firebase-token ueberein")
		return
	}
	input.SkipperID = user.ID

	var ownerID string
	err := app.db.QueryRowContext(r.Context(), `SELECT skipper_id FROM posts WHERE id = $1`, postID).Scan(&ownerID)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "post nicht gefunden")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht geprueft werden")
		return
	}
	if ownerID != user.ID {
		writeError(w, http.StatusForbidden, "nur der eigentuemer darf diesen post loeschen")
		return
	}

	_, err = app.db.ExecContext(r.Context(), `DELETE FROM posts WHERE id = $1 AND skipper_id = $2`, postID, user.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht geloescht werden")
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func (app *application) handleLikePost(w http.ResponseWriter, r *http.Request, postID string) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input likePostRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	input.SkipperID = strings.TrimSpace(input.SkipperID)
	if input.SkipperID != "" && input.SkipperID != user.ID {
		writeError(w, http.StatusForbidden, "skipper_id stimmt nicht mit dem firebase-token ueberein")
		return
	}
	input.SkipperID = user.ID

	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()

	exists, err := app.postExistsTx(r.Context(), tx, postID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht geprueft werden")
		return
	}
	if !exists {
		writeError(w, http.StatusNotFound, "post nicht gefunden")
		return
	}
	if err := upsertProfile(r.Context(), tx, user.ID, user.Name, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht gespeichert werden")
		return
	}

	var deleted int
	err = tx.QueryRowContext(
		r.Context(),
		`WITH removed AS (
			DELETE FROM post_likes
			WHERE post_id = $1 AND skipper_id = $2
			RETURNING 1
		) SELECT count(*) FROM removed`,
		postID,
		input.SkipperID,
	).Scan(&deleted)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "like konnte nicht verarbeitet werden")
		return
	}
	if deleted == 0 {
		_, err = tx.ExecContext(
			r.Context(),
			`INSERT INTO post_likes (post_id, skipper_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING`,
			postID,
			input.SkipperID,
		)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "like konnte nicht gespeichert werden")
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "like konnte nicht bestaetigt werden")
		return
	}

	post, err := app.getPost(r.Context(), postID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, post)
}

func (app *application) handleCreateComment(w http.ResponseWriter, r *http.Request, postID string) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input createCommentRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	input.SkipperID = strings.TrimSpace(input.SkipperID)
	if input.SkipperID != "" && input.SkipperID != user.ID {
		writeError(w, http.StatusForbidden, "skipper_id stimmt nicht mit dem firebase-token ueberein")
		return
	}
	input.SkipperID = user.ID
	input.SkipperName = defaultName(user.Name)
	input.Text = strings.TrimSpace(input.Text)
	if input.Text == "" {
		writeError(w, http.StatusBadRequest, "kommentartext fehlt")
		return
	}
	if len(input.Text) > 1200 {
		writeError(w, http.StatusBadRequest, "kommentar ist zu lang")
		return
	}

	commentID, err := newUUID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "id konnte nicht erzeugt werden")
		return
	}

	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()

	exists, err := app.postExistsTx(r.Context(), tx, postID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht geprueft werden")
		return
	}
	if !exists {
		writeError(w, http.StatusNotFound, "post nicht gefunden")
		return
	}
	if err := upsertProfile(r.Context(), tx, input.SkipperID, input.SkipperName, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht gespeichert werden")
		return
	}

	_, err = tx.ExecContext(
		r.Context(),
		`INSERT INTO comments (id, post_id, skipper_id, text) VALUES ($1, $2, $3, $4)`,
		commentID,
		postID,
		input.SkipperID,
		input.Text,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "kommentar konnte nicht gespeichert werden")
		return
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "kommentar konnte nicht bestaetigt werden")
		return
	}

	comment, err := app.getComment(r.Context(), commentID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "kommentar konnte nicht geladen werden")
		return
	}
	post, err := app.getPost(r.Context(), postID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "post konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusCreated, createCommentResponse{Post: post, Comment: comment})
}

func (app *application) handleListComments(w http.ResponseWriter, r *http.Request, postID string) {
	comments, err := app.listComments(r.Context(), postID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "kommentare konnten nicht geladen werden")
		slog.Error("list comments", "error", err)
		return
	}
	writeJSON(w, http.StatusOK, comments)
}

func (app *application) handlePresignUpload(w http.ResponseWriter, r *http.Request) {
	if _, ok := app.requireCrewspaceUser(w, r); !ok {
		return
	}
	var input presignUploadRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	contentType := strings.ToLower(strings.TrimSpace(input.ContentType))
	extension := cleanImageExtension(input.FileExtension)
	if !allowedImageContentType(contentType) || extension == "" {
		writeError(w, http.StatusBadRequest, "nur jpg, png, webp oder heic sind erlaubt")
		return
	}

	objectID, err := newUUID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "object key konnte nicht erzeugt werden")
		return
	}

	key := fmt.Sprintf("feed/%s/%s.%s", time.Now().UTC().Format("2006/01"), objectID, extension)

	if app.localUploads.enabled {
		uploadURL, publicURL, err := app.localUploads.presignPut(key, contentType, time.Now())
		if err != nil {
			writeError(w, http.StatusInternalServerError, "upload-url konnte nicht signiert werden")
			return
		}
		writeJSON(w, http.StatusOK, presignUploadResponse{
			UploadURL: uploadURL,
			PublicURL: publicURL,
			Method:    http.MethodPut,
			Headers: map[string]string{
				"Content-Type": contentType,
			},
		})
		return
	}

	if !app.storage.enabled {
		writeError(w, http.StatusServiceUnavailable, "object-storage ist nicht konfiguriert")
		return
	}

	uploadURL, publicURL, err := app.storage.presignPut(key, contentType)
	if err != nil {
		slog.Error("presign upload", "error", err)
		writeError(w, http.StatusInternalServerError, "upload-url konnte nicht signiert werden")
		return
	}

	writeJSON(w, http.StatusOK, presignUploadResponse{
		UploadURL: uploadURL,
		PublicURL: publicURL,
		Method:    http.MethodPut,
		Headers: map[string]string{
			"Content-Type": contentType,
		},
	})
}

func (app *application) handleLocalUpload(w http.ResponseWriter, r *http.Request) {
	if !app.localUploads.enabled {
		writeError(w, http.StatusServiceUnavailable, "lokale uploads sind nicht konfiguriert")
		return
	}

	relativePath := strings.TrimPrefix(r.URL.Path, "/uploads/local/")
	if !isSafeLocalUploadPath(relativePath) {
		writeError(w, http.StatusBadRequest, "ungueltiger upload-pfad")
		return
	}

	contentType := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Type")))
	if !app.localUploads.verifyPut(relativePath, contentType, r.URL.Query(), time.Now()) {
		writeError(w, http.StatusForbidden, "upload-signatur ist ungueltig oder abgelaufen")
		return
	}
	extension := strings.TrimPrefix(strings.ToLower(filepath.Ext(relativePath)), ".")
	if !allowedLocalMedia(contentType, extension) {
		writeError(w, http.StatusBadRequest, "dieser bild- oder audiotyp ist nicht erlaubt")
		return
	}

	targetPath := filepath.Join(app.localUploads.directory, filepath.FromSlash(relativePath))
	if err := os.MkdirAll(filepath.Dir(targetPath), 0755); err != nil {
		slog.Error("create upload directory", "error", err)
		writeError(w, http.StatusInternalServerError, "upload-verzeichnis konnte nicht erstellt werden")
		return
	}

	file, err := os.CreateTemp(filepath.Dir(targetPath), ".upload-*")
	if err != nil {
		slog.Error("open upload file", "error", err)
		writeError(w, http.StatusInternalServerError, "upload-datei konnte nicht erstellt werden")
		return
	}
	tempPath := file.Name()
	defer os.Remove(tempPath)

	reader := http.MaxBytesReader(w, r.Body, 20<<20)
	if _, err := io.Copy(file, reader); err != nil {
		_ = file.Close()
		writeError(w, http.StatusBadRequest, "medium ist zu gross oder konnte nicht gespeichert werden")
		return
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		writeError(w, http.StatusInternalServerError, "upload-datei konnte nicht gespeichert werden")
		return
	}
	if err := file.Chmod(0644); err != nil {
		_ = file.Close()
		writeError(w, http.StatusInternalServerError, "upload-datei konnte nicht vorbereitet werden")
		return
	}
	if err := file.Close(); err != nil {
		writeError(w, http.StatusInternalServerError, "upload-datei konnte nicht gespeichert werden")
		return
	}
	if err := os.Link(tempPath, targetPath); err != nil {
		if errors.Is(err, os.ErrExist) {
			writeError(w, http.StatusConflict, "upload-ziel existiert bereits")
			return
		}
		slog.Error("publish upload file", "error", err)
		writeError(w, http.StatusInternalServerError, "upload-datei konnte nicht veroeffentlicht werden")
		return
	}

	w.WriteHeader(http.StatusCreated)
}

func (app *application) handleLocalUploadDownload(w http.ResponseWriter, r *http.Request) {
	if !app.localUploads.enabled {
		http.NotFound(w, r)
		return
	}
	relativePath := strings.TrimPrefix(r.URL.Path, "/uploads/local/")
	if !isPublicLocalUploadPath(relativePath) {
		http.NotFound(w, r)
		return
	}
	root, err := os.OpenRoot(app.localUploads.directory)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer root.Close()

	segments := strings.Split(relativePath, "/")
	currentPath := ""
	for index, segment := range segments {
		if currentPath == "" {
			currentPath = segment
		} else {
			currentPath += "/" + segment
		}
		info, err := root.Lstat(currentPath)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			http.NotFound(w, r)
			return
		}
		if index < len(segments)-1 && !info.IsDir() {
			http.NotFound(w, r)
			return
		}
		if index == len(segments)-1 && !info.Mode().IsRegular() {
			http.NotFound(w, r)
			return
		}
	}
	file, err := root.Open(relativePath)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, filepath.Base(relativePath), info.ModTime(), file)
}

func (app *application) listPosts(ctx context.Context, skipperID string) ([]postResponse, error) {
	query := postSelectSQL()
	args := []any{}
	if skipperID != "" {
		query += " WHERE p.skipper_id = $1"
		args = append(args, skipperID)
	}
	query += " ORDER BY p.created_at DESC LIMIT 100"

	rows, err := app.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	posts := make([]postResponse, 0)
	for rows.Next() {
		post, err := scanPost(rows)
		if err != nil {
			return nil, err
		}
		posts = append(posts, post)
	}
	return posts, rows.Err()
}

func (app *application) getPost(ctx context.Context, postID string) (postResponse, error) {
	query := postSelectSQL() + " WHERE p.id = $1"
	row := app.db.QueryRowContext(ctx, query, postID)
	return scanPost(row)
}

func (app *application) getProfile(ctx context.Context, profileID string, viewerID string) (profileResponse, error) {
	var profile profileResponse
	var profileImage sql.NullString
	var homeHarbour sql.NullString
	var bio sql.NullString
	var postIDsJSON string
	var followerCount int64
	var followingCount int64
	var isFollowed bool

	err := app.db.QueryRowContext(
		ctx,
		`SELECT
			sp.id,
			sp.name,
			sp.boat_type,
			sp.profile_image_url,
			sp.home_harbour,
			sp.bio,
			COALESCE((SELECT json_agg(p.id ORDER BY p.created_at DESC) FROM posts p WHERE p.skipper_id = sp.id), '[]'::json)::text,
			(SELECT count(*) FROM profile_follows pf WHERE pf.followed_id = sp.id),
			(SELECT count(*) FROM profile_follows pf WHERE pf.follower_id = sp.id),
			EXISTS (SELECT 1 FROM profile_follows pf WHERE pf.follower_id = $2 AND pf.followed_id = sp.id)
		FROM skipper_profiles sp
		WHERE sp.id = $1`,
		profileID,
		viewerID,
	).Scan(
		&profile.ID,
		&profile.Name,
		&profile.BoatType,
		&profileImage,
		&homeHarbour,
		&bio,
		&postIDsJSON,
		&followerCount,
		&followingCount,
		&isFollowed,
	)
	if err != nil {
		return profile, err
	}

	postIDs, err := decodeStringArray(postIDsJSON)
	if err != nil {
		return profile, err
	}
	profile.ProfileImageURL = nullStringPtr(profileImage)
	profile.HomeHarbour = nullStringPtr(homeHarbour)
	profile.Bio = nullStringPtr(bio)
	profile.PostIDs = postIDs
	profile.FollowerCount = int(followerCount)
	profile.FollowingCount = int(followingCount)
	profile.IsFollowed = isFollowed
	return profile, nil
}

func (app *application) listComments(ctx context.Context, postID string) ([]commentResponse, error) {
	rows, err := app.db.QueryContext(
		ctx,
		`SELECT c.id, c.post_id, c.skipper_id, sp.name, c.text, c.created_at
		FROM comments c
		JOIN skipper_profiles sp ON sp.id = c.skipper_id
		WHERE c.post_id = $1
		ORDER BY c.created_at ASC
		LIMIT 300`,
		postID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	comments := make([]commentResponse, 0)
	for rows.Next() {
		var comment commentResponse
		if err := rows.Scan(
			&comment.ID,
			&comment.PostID,
			&comment.SkipperID,
			&comment.SkipperName,
			&comment.Text,
			&comment.CreatedAt,
		); err != nil {
			return nil, err
		}
		comments = append(comments, comment)
	}
	return comments, rows.Err()
}

func (app *application) getComment(ctx context.Context, commentID string) (commentResponse, error) {
	var comment commentResponse
	err := app.db.QueryRowContext(
		ctx,
		`SELECT c.id, c.post_id, c.skipper_id, sp.name, c.text, c.created_at
		FROM comments c
		JOIN skipper_profiles sp ON sp.id = c.skipper_id
		WHERE c.id = $1`,
		commentID,
	).Scan(
		&comment.ID,
		&comment.PostID,
		&comment.SkipperID,
		&comment.SkipperName,
		&comment.Text,
		&comment.CreatedAt,
	)
	return comment, err
}

func (app *application) postExistsTx(ctx context.Context, tx *sql.Tx, postID string) (bool, error) {
	var exists bool
	err := tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM posts WHERE id = $1)`, postID).Scan(&exists)
	return exists, err
}

func (app *application) profileExistsTx(ctx context.Context, tx *sql.Tx, profileID string) (bool, error) {
	var exists bool
	err := tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM skipper_profiles WHERE id = $1)`, profileID).Scan(&exists)
	return exists, err
}

func (app *application) refreshFollowCountsTx(ctx context.Context, tx *sql.Tx, followerID string, followedID string) error {
	_, err := tx.ExecContext(
		ctx,
		`UPDATE skipper_profiles
		SET following_count = (SELECT count(*) FROM profile_follows WHERE follower_id = $1),
			updated_at = now()
		WHERE id = $1`,
		followerID,
	)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(
		ctx,
		`UPDATE skipper_profiles
		SET follower_count = (SELECT count(*) FROM profile_follows WHERE followed_id = $1),
			updated_at = now()
		WHERE id = $1`,
		followedID,
	)
	return err
}

func postSelectSQL() string {
	return `SELECT
		p.id,
		p.skipper_id,
		sp.name,
		sp.profile_image_url,
		p.text,
		p.image_url,
		COALESCE((SELECT json_agg(pl.skipper_id ORDER BY pl.created_at DESC) FROM post_likes pl WHERE pl.post_id = p.id), '[]'::json)::text,
		COALESCE((SELECT json_agg(c.id ORDER BY c.created_at ASC) FROM comments c WHERE c.post_id = p.id), '[]'::json)::text,
		(SELECT count(*) FROM post_likes pl WHERE pl.post_id = p.id),
		(SELECT count(*) FROM comments c WHERE c.post_id = p.id),
		p.created_at,
		p.updated_at,
		sp.boat_type,
		sp.home_harbour,
		sp.bio,
		sp.follower_count,
		sp.following_count,
		COALESCE((SELECT json_agg(pp.id ORDER BY pp.created_at DESC) FROM posts pp WHERE pp.skipper_id = sp.id), '[]'::json)::text
	FROM posts p
	JOIN skipper_profiles sp ON sp.id = p.skipper_id`
}

type rowScanner interface {
	Scan(...any) error
}

func scanPost(row rowScanner) (postResponse, error) {
	var post postResponse
	var profileImage sql.NullString
	var imageURL sql.NullString
	var homeHarbour sql.NullString
	var bio sql.NullString
	var likedJSON string
	var commentsJSON string
	var postIDsJSON string
	var boatType string
	var likeCount int64
	var commentCount int64
	var followerCount int64
	var followingCount int64

	err := row.Scan(
		&post.ID,
		&post.SkipperID,
		&post.SkipperName,
		&profileImage,
		&post.Text,
		&imageURL,
		&likedJSON,
		&commentsJSON,
		&likeCount,
		&commentCount,
		&post.CreatedAt,
		&post.UpdatedAt,
		&boatType,
		&homeHarbour,
		&bio,
		&followerCount,
		&followingCount,
		&postIDsJSON,
	)
	if err != nil {
		return post, err
	}

	likedBy, err := decodeStringArray(likedJSON)
	if err != nil {
		return post, err
	}
	commentIDs, err := decodeStringArray(commentsJSON)
	if err != nil {
		return post, err
	}
	postIDs, err := decodeStringArray(postIDsJSON)
	if err != nil {
		return post, err
	}

	post.SkipperProfileImageURL = nullStringPtr(profileImage)
	post.ImageURL = nullStringPtr(imageURL)
	post.LikedBySkipperIDs = likedBy
	post.CommentIDs = commentIDs
	post.LikeCount = int(likeCount)
	post.CommentCount = int(commentCount)
	post.Profile = &profileResponse{
		ID:              post.SkipperID,
		Name:            post.SkipperName,
		BoatType:        boatType,
		ProfileImageURL: nullStringPtr(profileImage),
		HomeHarbour:     nullStringPtr(homeHarbour),
		Bio:             nullStringPtr(bio),
		PostIDs:         postIDs,
		FollowerCount:   int(followerCount),
		FollowingCount:  int(followingCount),
	}
	return post, nil
}

func upsertProfile(ctx context.Context, db dbRunner, skipperID string, name string, profileImageURL *string) error {
	_, err := db.ExecContext(
		ctx,
		`INSERT INTO skipper_profiles (id, name, profile_image_url)
		VALUES ($1, $2, $3)
		ON CONFLICT (id) DO UPDATE SET
			profile_image_url = COALESCE(EXCLUDED.profile_image_url, skipper_profiles.profile_image_url),
			updated_at = now()`,
		skipperID,
		defaultName(name),
		nullableArg(profileImageURL),
	)
	return err
}

func ensureProfile(ctx context.Context, db dbRunner, skipperID string) error {
	_, err := db.ExecContext(
		ctx,
		`INSERT INTO skipper_profiles (id, name)
		VALUES ($1, 'Skipper')
		ON CONFLICT (id) DO NOTHING`,
		skipperID,
	)
	return err
}

func (cfg storageConfig) presignPut(key string, contentType string) (string, string, error) {
	now := time.Now().UTC()
	dateStamp := now.Format("20060102")
	amzDate := now.Format("20060102T150405Z")
	credentialScope := fmt.Sprintf("%s/%s/s3/aws4_request", dateStamp, cfg.region)
	credential := fmt.Sprintf("%s/%s", cfg.accessKeyID, credentialScope)

	objectPath := "/" + strings.Trim(cfg.bucket, "/") + "/" + strings.TrimLeft(key, "/")
	uploadURL := *cfg.endpoint
	uploadURL.Path = strings.TrimRight(cfg.endpoint.Path, "/") + objectPath

	query := uploadURL.Query()
	query.Set("X-Amz-Algorithm", "AWS4-HMAC-SHA256")
	query.Set("X-Amz-Credential", credential)
	query.Set("X-Amz-Date", amzDate)
	query.Set("X-Amz-Expires", fmt.Sprintf("%.0f", cfg.presignTTL.Seconds()))
	query.Set("X-Amz-SignedHeaders", "content-type;host")

	canonicalURI := escapePath(uploadURL.Path)
	canonicalQuery := query.Encode()
	canonicalHeaders := fmt.Sprintf("content-type:%s\nhost:%s\n", contentType, uploadURL.Host)
	canonicalRequest := strings.Join([]string{
		http.MethodPut,
		canonicalURI,
		canonicalQuery,
		canonicalHeaders,
		"content-type;host",
		"UNSIGNED-PAYLOAD",
	}, "\n")

	hashedRequest := sha256.Sum256([]byte(canonicalRequest))
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		credentialScope,
		hex.EncodeToString(hashedRequest[:]),
	}, "\n")

	signature := hex.EncodeToString(hmacSHA256(signingKey(cfg.secretKey, dateStamp, cfg.region, "s3"), stringToSign))
	query.Set("X-Amz-Signature", signature)
	uploadURL.RawQuery = query.Encode()

	publicURL := strings.TrimRight(cfg.publicBase, "/") + "/" + url.PathEscape(strings.TrimLeft(key, "/"))
	publicURL = strings.ReplaceAll(publicURL, "%2F", "/")
	return uploadURL.String(), publicURL, nil
}

func loadStorageConfig() storageConfig {
	endpointRaw := strings.TrimSpace(os.Getenv("S3_ENDPOINT"))
	region := strings.TrimSpace(os.Getenv("S3_REGION"))
	bucket := strings.TrimSpace(os.Getenv("S3_BUCKET"))
	accessKeyID := strings.TrimSpace(os.Getenv("S3_ACCESS_KEY_ID"))
	secretKey := strings.TrimSpace(os.Getenv("S3_SECRET_ACCESS_KEY"))
	publicBase := strings.TrimSpace(os.Getenv("S3_PUBLIC_BASE_URL"))

	if endpointRaw == "" || region == "" || bucket == "" || accessKeyID == "" || secretKey == "" || publicBase == "" {
		return storageConfig{presignTTL: 15 * time.Minute}
	}

	endpoint, err := url.Parse(endpointRaw)
	if err != nil || endpoint.Scheme == "" || endpoint.Host == "" {
		slog.Warn("invalid S3_ENDPOINT; uploads disabled", "endpoint", endpointRaw)
		return storageConfig{presignTTL: 15 * time.Minute}
	}

	return storageConfig{
		enabled:     true,
		endpoint:    endpoint,
		region:      region,
		bucket:      bucket,
		accessKeyID: accessKeyID,
		secretKey:   secretKey,
		publicBase:  publicBase,
		presignTTL:  15 * time.Minute,
	}
}

func loadLocalUploadConfig() localUploadConfig {
	publicBase := strings.TrimRight(strings.TrimSpace(os.Getenv("LOCAL_UPLOAD_PUBLIC_BASE_URL")), "/")
	if publicBase == "" {
		return localUploadConfig{presignTTL: 15 * time.Minute}
	}
	signingSecret := strings.TrimSpace(os.Getenv("LOCAL_UPLOAD_SIGNING_SECRET"))
	if len([]byte(signingSecret)) < 32 {
		slog.Warn("local uploads disabled; LOCAL_UPLOAD_SIGNING_SECRET must contain at least 32 bytes")
		return localUploadConfig{presignTTL: 15 * time.Minute}
	}

	directory := strings.TrimSpace(os.Getenv("LOCAL_UPLOAD_DIR"))
	if directory == "" {
		directory = "/home/sep/social-feed-uploads"
	}
	if err := os.MkdirAll(directory, 0755); err != nil {
		slog.Warn("local uploads disabled; directory unavailable", "directory", directory, "error", err)
		return localUploadConfig{presignTTL: 15 * time.Minute}
	}

	return localUploadConfig{
		enabled:    true,
		directory:  directory,
		publicBase: publicBase,
		signingKey: []byte(signingSecret),
		presignTTL: 15 * time.Minute,
	}
}

func (cfg localUploadConfig) presignPut(
	relativePath string,
	contentType string,
	now time.Time,
) (string, string, error) {
	if !cfg.enabled || len(cfg.signingKey) < 32 || !isSafeLocalUploadPath(relativePath) {
		return "", "", errors.New("local uploads are not configured")
	}
	contentType = strings.ToLower(strings.TrimSpace(contentType))
	expires := now.UTC().Add(cfg.presignTTL).Unix()
	signature := cfg.signPut(relativePath, contentType, expires)
	uploadURL, err := url.Parse(cfg.publicBase + "/uploads/local/" + relativePath)
	if err != nil {
		return "", "", err
	}
	query := uploadURL.Query()
	query.Set("expires", strconv.FormatInt(expires, 10))
	query.Set("signature", signature)
	uploadURL.RawQuery = query.Encode()
	publicURL := cfg.publicBase + "/uploads/local/" + relativePath
	return uploadURL.String(), publicURL, nil
}

func (cfg localUploadConfig) verifyPut(
	relativePath string,
	contentType string,
	query url.Values,
	now time.Time,
) bool {
	if !cfg.enabled || len(cfg.signingKey) < 32 || !isSafeLocalUploadPath(relativePath) {
		return false
	}
	expires, err := strconv.ParseInt(strings.TrimSpace(query.Get("expires")), 10, 64)
	if err != nil {
		return false
	}
	nowUnix := now.UTC().Unix()
	if expires <= nowUnix || expires > now.Add(cfg.presignTTL+time.Minute).Unix() {
		return false
	}
	provided, err := hex.DecodeString(strings.TrimSpace(query.Get("signature")))
	if err != nil || len(provided) != sha256.Size {
		return false
	}
	expected, err := hex.DecodeString(cfg.signPut(
		relativePath,
		strings.ToLower(strings.TrimSpace(contentType)),
		expires,
	))
	return err == nil && hmac.Equal(provided, expected)
}

func (cfg localUploadConfig) signPut(relativePath string, contentType string, expires int64) string {
	canonical := strings.Join([]string{
		http.MethodPut,
		"/" + relativePath,
		strings.ToLower(strings.TrimSpace(contentType)),
		strconv.FormatInt(expires, 10),
	}, "\n")
	mac := hmac.New(sha256.New, cfg.signingKey)
	_, _ = mac.Write([]byte(canonical))
	return hex.EncodeToString(mac.Sum(nil))
}

func isSafeLocalUploadPath(path string) bool {
	if path == "" || strings.HasPrefix(path, "/") || strings.Contains(path, "\\") {
		return false
	}
	cleaned := filepath.Clean(path)
	allowedRoot := strings.HasPrefix(cleaned, "feed/") || strings.HasPrefix(cleaned, "crewspace/")
	return cleaned == path && !strings.HasPrefix(cleaned, "..") && allowedRoot
}

func isPublicLocalUploadPath(path string) bool {
	if !isSafeLocalUploadPath(path) {
		return false
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "" || strings.HasPrefix(segment, ".") {
			return false
		}
	}
	return true
}

func commonHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Expose-Headers", "ETag")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func readJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	return decoder.Decode(dst)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("write json", "error", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}

func decodeStringArray(raw string) ([]string, error) {
	if strings.TrimSpace(raw) == "" {
		return []string{}, nil
	}
	var values []string
	if err := json.Unmarshal([]byte(raw), &values); err != nil {
		return nil, err
	}
	if values == nil {
		return []string{}, nil
	}
	return values, nil
}

func cleanOptionalURL(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

func cleanOptionalText(value *string, maxLength int) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	if maxLength > 0 && len(trimmed) > maxLength {
		trimmed = trimmed[:maxLength]
	}
	return &trimmed
}

func nullableArg(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func nullStringPtr(value sql.NullString) *string {
	if !value.Valid || value.String == "" {
		return nil
	}
	return &value.String
}

func defaultName(name string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return "Skipper"
	}
	if len(trimmed) > 80 {
		return trimmed[:80]
	}
	return trimmed
}

func isHTTPURL(raw string) bool {
	parsed, err := url.Parse(raw)
	return err == nil && parsed.Host != "" && (parsed.Scheme == "http" || parsed.Scheme == "https")
}

func allowedImageContentType(contentType string) bool {
	switch contentType {
	case "image/jpeg", "image/png", "image/webp", "image/heic", "image/heif":
		return true
	default:
		return false
	}
}

func allowedCrewspaceMediaType(contentType string) bool {
	if allowedImageContentType(contentType) {
		return true
	}
	switch contentType {
	case "audio/mp4", "audio/m4a", "audio/aac", "audio/x-m4a":
		return true
	}
	return allowedCrewspaceDocumentType(contentType)
}

func allowedCrewspaceDocumentType(contentType string) bool {
	switch contentType {
	case "application/pdf",
		"application/msword",
		"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
		"application/vnd.ms-excel",
		"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
		"application/vnd.ms-powerpoint",
		"application/vnd.openxmlformats-officedocument.presentationml.presentation",
		"application/rtf", "text/rtf", "text/plain", "text/csv", "application/zip",
		"application/x-iwork-pages-sffpages",
		"application/x-iwork-numbers-sffnumbers",
		"application/x-iwork-keynote-sffkey":
		return true
	default:
		return false
	}
}

func allowedLocalMedia(contentType string, extension string) bool {
	if allowedImageContentType(contentType) {
		return cleanImageExtension(extension) != ""
	}
	if !allowedCrewspaceMediaType(contentType) {
		return false
	}
	return cleanCrewspaceMediaExtension(extension) != ""
}

func cleanCrewspaceMediaExtension(extension string) string {
	if imageExtension := cleanImageExtension(extension); imageExtension != "" {
		return imageExtension
	}
	extension = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(extension)), ".")
	switch extension {
	case "m4a", "mp4", "aac", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
		"rtf", "txt", "csv", "zip", "pages", "numbers", "key":
		return extension
	default:
		return ""
	}
}

func cleanImageExtension(extension string) string {
	extension = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(extension)), ".")
	switch extension {
	case "jpg", "jpeg":
		return "jpg"
	case "png", "webp", "heic", "heif":
		return extension
	default:
		return ""
	}
}

func envString(key string, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func newUUID() (string, error) {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	id := hex.EncodeToString(bytes[:])
	return id[0:8] + "-" + id[8:12] + "-" + id[12:16] + "-" + id[16:20] + "-" + id[20:32], nil
}

func signingKey(secret string, dateStamp string, region string, service string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secret), dateStamp)
	kRegion := hmacSHA256(kDate, region)
	kService := hmacSHA256(kRegion, service)
	return hmacSHA256(kService, "aws4_request")
}

func hmacSHA256(key []byte, value string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(value))
	return mac.Sum(nil)
}

func escapePath(rawPath string) string {
	segments := strings.Split(rawPath, "/")
	for index, segment := range segments {
		segments[index] = url.PathEscape(segment)
	}
	return strings.Join(segments, "/")
}
