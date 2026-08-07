package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type firebaseUser struct {
	ID    string
	Name  string
	Email string
}

type crewspaceConversationResponse struct {
	ID            string     `json:"id"`
	Title         string     `json:"title"`
	Kind          string     `json:"kind"`
	MemberIDs     []string   `json:"member_ids"`
	MemberNames   []string   `json:"member_names"`
	LastMessage   *string    `json:"last_message"`
	LastMessageAt *time.Time `json:"last_message_at"`
	UnreadCount   int        `json:"unread_count"`
	ChatAvailable bool       `json:"chat_available"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

type crewspaceMessageResponse struct {
	ID              string                  `json:"id"`
	ConversationID  string                  `json:"conversation_id"`
	SenderID        string                  `json:"sender_id"`
	SenderName      string                  `json:"sender_name"`
	ClientMessageID string                  `json:"client_message_id"`
	Text            string                  `json:"text"`
	MediaURL        *string                 `json:"media_url"`
	MediaType       *string                 `json:"media_type"`
	MediaDuration   *float64                `json:"media_duration_seconds"`
	Poll            *crewspacePollResponse  `json:"poll"`
	Event           *crewspaceEventResponse `json:"event"`
	CreatedAt       time.Time               `json:"created_at"`
}

type storedCrewspaceMessage struct {
	Message crewspaceMessageResponse
	PollID  sql.NullString
	EventID sql.NullString
}

type crewspacePollResponse struct {
	ID             string                        `json:"id"`
	Question       string                        `json:"question"`
	AllowsMultiple bool                          `json:"allows_multiple"`
	ClosesAt       *time.Time                    `json:"closes_at"`
	TotalVotes     int                           `json:"total_votes"`
	Options        []crewspacePollOptionResponse `json:"options"`
}

type crewspacePollOptionResponse struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	VoteCount  int    `json:"vote_count"`
	IsSelected bool   `json:"is_selected"`
}

type crewspaceEventResponse struct {
	ID                string    `json:"id"`
	ConversationID    *string   `json:"conversation_id"`
	ConversationTitle *string   `json:"conversation_title"`
	CreatorID         string    `json:"creator_id"`
	CreatorName       string    `json:"creator_name"`
	Title             string    `json:"title"`
	StartsAt          time.Time `json:"starts_at"`
	EndsAt            time.Time `json:"ends_at"`
	Location          *string   `json:"location"`
	Notes             *string   `json:"notes"`
	AttachmentURL     *string   `json:"attachment_url"`
	AttachmentName    *string   `json:"attachment_name"`
	AttachmentType    *string   `json:"attachment_content_type"`
}

type crewspaceSkipperResponse struct {
	ID              string  `json:"id"`
	Name            string  `json:"name"`
	BoatType        string  `json:"boat_type"`
	HomeHarbour     *string `json:"home_harbour"`
	Bio             *string `json:"bio"`
	ProfileImageURL *string `json:"profile_image_url"`
}

type crewspaceGroupInfoResponse struct {
	ID        string                         `json:"id"`
	Title     string                         `json:"title"`
	Info      string                         `json:"info"`
	CreatedBy string                         `json:"created_by"`
	CanManage bool                           `json:"can_manage"`
	Members   []crewspaceGroupMemberResponse `json:"members"`
}

type crewspaceGroupMemberResponse struct {
	SkipperID      string    `json:"skipper_id"`
	Name           string    `json:"name"`
	ProfileImage   *string   `json:"profile_image_url"`
	PermissionRole string    `json:"permission_role"`
	CrewRole       string    `json:"crew_role"`
	IsOnBoard      bool      `json:"is_on_board"`
	JoinedAt       time.Time `json:"joined_at"`
}

type createCrewspaceDirectRequest struct {
	SkipperID string `json:"skipper_id"`
}

type createCrewspaceGroupRequest struct {
	Title     string   `json:"title"`
	Info      string   `json:"info"`
	MemberIDs []string `json:"member_ids"`
}

type updateCrewspaceGroupRequest struct {
	Title string `json:"title"`
	Info  string `json:"info"`
}

type updateCrewspaceMemberRequest struct {
	SkipperID string `json:"skipper_id"`
	CrewRole  string `json:"crew_role"`
	IsOnBoard bool   `json:"is_on_board"`
}

type createCrewspaceMessageRequest struct {
	ClientMessageID string   `json:"client_message_id"`
	Text            string   `json:"text"`
	MediaURL        *string  `json:"media_url"`
	MediaType       *string  `json:"media_type"`
	MediaDuration   *float64 `json:"media_duration_seconds"`
}

type createCrewspaceEventRequest struct {
	ConversationID *string   `json:"conversation_id"`
	Title          string    `json:"title"`
	StartsAt       time.Time `json:"starts_at"`
	EndsAt         time.Time `json:"ends_at"`
	Location       *string   `json:"location"`
	Notes          *string   `json:"notes"`
	AttachmentURL  *string   `json:"attachment_url"`
	AttachmentName *string   `json:"attachment_name"`
	AttachmentType *string   `json:"attachment_content_type"`
}

type createCrewspacePollRequest struct {
	Question       string     `json:"question"`
	Options        []string   `json:"options"`
	AllowsMultiple bool       `json:"allows_multiple"`
	ClosesAt       *time.Time `json:"closes_at"`
}

type voteCrewspacePollRequest struct {
	OptionIDs []string `json:"option_ids"`
}

type shareCrewspaceEventRequest struct {
	ConversationID string `json:"conversation_id"`
}

func (app *application) handleCrewspaceSkipper(w http.ResponseWriter, r *http.Request) {
	if _, ok := app.requireCrewspaceUser(w, r); !ok {
		return
	}
	targetID := strings.TrimSpace(strings.TrimPrefix(r.URL.Path, "/crewspace/skippers/"))
	if targetID == "" || strings.Contains(targetID, "/") {
		http.NotFound(w, r)
		return
	}

	skipper, err := app.getCrewspaceSkipper(r.Context(), targetID)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "skipper nicht gefunden")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "skipper konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, skipper)
}

func (app *application) handleListCrewspaceConversations(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	if err := upsertProfile(r.Context(), app.db, user.ID, user.Name, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht vorbereitet werden")
		return
	}

	conversations, err := app.listCrewspaceConversations(r.Context(), user.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "unterhaltungen konnten nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, conversations)
}

func (app *application) handleCreateCrewspaceDirect(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input createCrewspaceDirectRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	targetID := strings.TrimSpace(input.SkipperID)
	if targetID == "" || targetID == user.ID {
		writeError(w, http.StatusBadRequest, "gueltige fremde skipper_id erforderlich")
		return
	}
	if app.identity == nil {
		writeError(w, http.StatusServiceUnavailable, "firebase-authentifizierung ist nicht konfiguriert")
		return
	}
	target, err := app.identity.LookupUser(r.Context(), targetID)
	if err != nil {
		writeError(w, http.StatusNotFound, "skipper nicht gefunden")
		return
	}

	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()
	if err := lockCrewspacePair(r.Context(), tx, user.ID, target.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "direktchat konnte nicht gesperrt werden")
		return
	}
	if err := upsertProfile(r.Context(), tx, user.ID, user.Name, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "eigenes profil konnte nicht gespeichert werden")
		return
	}
	if err := upsertProfile(r.Context(), tx, target.ID, target.Name, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "zielprofil konnte nicht gespeichert werden")
		return
	}
	blocked, err := app.usersHaveCrewspaceBlock(r.Context(), tx, user.ID, target.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "chat konnte nicht geprueft werden")
		return
	}
	if blocked {
		writeChatUnavailable(w)
		return
	}

	ids := []string{user.ID, target.ID}
	conversationID, err := findCrewspaceDirectConversation(r.Context(), tx, user.ID, target.ID)
	if errors.Is(err, sql.ErrNoRows) {
		conversationID, err = newUUID()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "id konnte nicht erzeugt werden")
			return
		}
		legacyKey := legacyCrewspaceDirectKey(user.ID, target.ID)
		var legacyKeyOccupied bool
		if err := tx.QueryRowContext(
			r.Context(),
			`SELECT EXISTS (
				SELECT 1 FROM crewspace_conversations WHERE direct_key = $1
			)`,
			legacyKey,
		).Scan(&legacyKeyOccupied); err != nil {
			writeError(w, http.StatusInternalServerError, "direktchat konnte nicht geprueft werden")
			return
		}
		var compatibleLegacyKey any = legacyKey
		if legacyKeyOccupied {
			compatibleLegacyKey = nil
		}
		result, err := tx.ExecContext(
			r.Context(),
			`INSERT INTO crewspace_conversations (
				id, title, kind, direct_key, direct_user_low, direct_user_high, created_by
			 )
			 VALUES ($1, $2, 'direct', $3, LEAST($4, $5), GREATEST($4, $5), $6)
			 ON CONFLICT DO NOTHING`,
			conversationID,
			defaultName(target.Name),
			compatibleLegacyKey,
			user.ID,
			target.ID,
			user.ID,
		)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "direktchat konnte nicht erstellt werden")
			return
		}
		inserted, err := result.RowsAffected()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "direktchat konnte nicht bestaetigt werden")
			return
		}
		if inserted == 0 {
			conversationID, err = findCrewspaceDirectConversation(r.Context(), tx, user.ID, target.ID)
			if err != nil {
				writeError(w, http.StatusConflict, "direktchat konnte nicht eindeutig zugeordnet werden")
				return
			}
		}
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "direktchat konnte nicht geprueft werden")
		return
	}
	if _, err := tx.ExecContext(
		r.Context(),
		`UPDATE crewspace_conversations
		 SET direct_user_low = LEAST($2, $3),
		     direct_user_high = GREATEST($2, $3)
		 WHERE id = $1 AND kind = 'direct'`,
		conversationID,
		user.ID,
		target.ID,
	); err != nil {
		writeError(w, http.StatusConflict, "direktchat konnte nicht normalisiert werden")
		return
	}
	for _, memberID := range ids {
		role := "member"
		if memberID == user.ID {
			role = "owner"
		}
		if _, err := tx.ExecContext(
			r.Context(),
			`INSERT INTO crewspace_members (conversation_id, skipper_id, role)
			VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
			conversationID,
			memberID,
			role,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "chatmitglieder konnten nicht gespeichert werden")
			return
		}
	}
	if _, err := tx.ExecContext(
		r.Context(),
		`UPDATE crewspace_members SET hidden_at = NULL WHERE conversation_id = $1 AND skipper_id = $2`,
		conversationID,
		user.ID,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "direktchat konnte nicht eingeblendet werden")
		return
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "direktchat konnte nicht bestaetigt werden")
		return
	}
	conversation, err := app.getCrewspaceConversation(r.Context(), user.ID, conversationID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "direktchat konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusCreated, conversation)
}

func (app *application) handleCreateCrewspaceGroup(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input createCrewspaceGroupRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.Title = strings.TrimSpace(input.Title)
	input.Info = strings.TrimSpace(input.Info)
	if input.Title == "" || len(input.Title) > 80 {
		writeError(w, http.StatusBadRequest, "gruppenname ist erforderlich und darf hoechstens 80 zeichen haben")
		return
	}
	if len(input.Info) > 1000 {
		writeError(w, http.StatusBadRequest, "gruppeninfo darf hoechstens 1000 zeichen haben")
		return
	}

	members := uniqueNonEmptyStrings(input.MemberIDs)
	members = removeString(members, user.ID)
	if len(members) == 0 || len(members) > 49 {
		writeError(w, http.StatusBadRequest, "eine gruppe braucht 1 bis 49 weitere mitglieder")
		return
	}

	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()
	if err := upsertProfile(r.Context(), tx, user.ID, user.Name, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "eigenes profil konnte nicht gespeichert werden")
		return
	}
	for _, memberID := range members {
		var exists bool
		if err := tx.QueryRowContext(r.Context(), `SELECT EXISTS (SELECT 1 FROM skipper_profiles WHERE id = $1)`, memberID).Scan(&exists); err != nil || !exists {
			writeError(w, http.StatusBadRequest, "mindestens eine skipper_id existiert nicht")
			return
		}
	}

	conversationID, err := newUUID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "id konnte nicht erzeugt werden")
		return
	}
	if _, err := tx.ExecContext(
		r.Context(),
		`INSERT INTO crewspace_conversations (id, title, info, kind, created_by) VALUES ($1, $2, $3, 'group', $4)`,
		conversationID,
		input.Title,
		input.Info,
		user.ID,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "gruppe konnte nicht erstellt werden")
		return
	}
	allMembers := append([]string{user.ID}, members...)
	for _, memberID := range allMembers {
		role := "member"
		if memberID == user.ID {
			role = "owner"
		}
		if _, err := tx.ExecContext(
			r.Context(),
			`INSERT INTO crewspace_members (conversation_id, skipper_id, role) VALUES ($1, $2, $3)`,
			conversationID,
			memberID,
			role,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "gruppenmitglieder konnten nicht gespeichert werden")
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "gruppe konnte nicht bestaetigt werden")
		return
	}
	conversation, err := app.getCrewspaceConversation(r.Context(), user.ID, conversationID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "gruppe konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusCreated, conversation)
}

func (app *application) handleCrewspacePresignUpload(w http.ResponseWriter, r *http.Request) {
	if _, ok := app.requireCrewspaceUser(w, r); !ok {
		return
	}
	var input presignUploadRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}

	contentType := strings.ToLower(strings.TrimSpace(input.ContentType))
	extension := cleanCrewspaceMediaExtension(input.FileExtension)
	if !allowedCrewspaceMediaType(contentType) || extension == "" {
		writeError(w, http.StatusBadRequest, "dieser bild-, audio- oder dokumenttyp ist nicht erlaubt")
		return
	}
	objectID, err := newUUID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "object key konnte nicht erzeugt werden")
		return
	}
	key := fmt.Sprintf("crewspace/%s/%s.%s", time.Now().UTC().Format("2006/01"), objectID, extension)

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
			Headers:   map[string]string{"Content-Type": contentType},
		})
		return
	}
	if !app.storage.enabled {
		writeError(w, http.StatusServiceUnavailable, "medien-upload ist nicht konfiguriert")
		return
	}
	uploadURL, publicURL, err := app.storage.presignPut(key, contentType)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "upload-url konnte nicht signiert werden")
		return
	}
	writeJSON(w, http.StatusOK, presignUploadResponse{
		UploadURL: uploadURL,
		PublicURL: publicURL,
		Method:    http.MethodPut,
		Headers:   map[string]string{"Content-Type": contentType},
	})
}

func (app *application) handleCrewspaceConversationRoute(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/crewspace/conversations/"), "/"), "/")
	if len(parts) == 1 && parts[0] != "" && r.Method == http.MethodDelete {
		app.handleRemoveCrewspaceConversation(w, r, user, parts[0])
		return
	}
	if len(parts) < 2 || len(parts) > 3 || parts[0] == "" {
		http.NotFound(w, r)
		return
	}
	conversationID := parts[0]
	switch {
	case len(parts) == 2 && parts[1] == "profile" && r.Method == http.MethodGet:
		app.handleGetCrewspaceGroupInfo(w, r, user, conversationID)
	case len(parts) == 2 && parts[1] == "profile" && r.Method == http.MethodPut:
		app.handleUpdateCrewspaceGroupInfo(w, r, user, conversationID)
	case len(parts) == 2 && parts[1] == "members" && r.Method == http.MethodPost:
		app.handleAddCrewspaceGroupMember(w, r, user, conversationID)
	case len(parts) == 3 && parts[1] == "members" && r.Method == http.MethodPut:
		app.handleUpdateCrewspaceGroupMember(w, r, user, conversationID, parts[2])
	case len(parts) == 3 && parts[1] == "members" && r.Method == http.MethodDelete:
		app.handleRemoveCrewspaceGroupMember(w, r, user, conversationID, parts[2])
	case len(parts) == 2 && parts[1] == "messages" && r.Method == http.MethodGet:
		app.handleListCrewspaceMessages(w, r, user, conversationID)
	case len(parts) == 3 && parts[1] == "messages" && parts[2] == "page" && r.Method == http.MethodGet:
		app.handleListCrewspaceMessagesPage(w, r, user, conversationID)
	case len(parts) == 2 && parts[1] == "messages" && r.Method == http.MethodPost:
		app.handleCreateCrewspaceMessage(w, r, user, conversationID)
	case len(parts) == 2 && parts[1] == "polls" && r.Method == http.MethodPost:
		app.handleCreateCrewspacePoll(w, r, user, conversationID)
	case len(parts) == 2 && parts[1] == "read" && r.Method == http.MethodPost:
		app.handleMarkCrewspaceRead(w, r, user, conversationID)
	default:
		http.NotFound(w, r)
	}
}

func (app *application) handleGetCrewspaceGroupInfo(
	w http.ResponseWriter,
	r *http.Request,
	user firebaseUser,
	conversationID string,
) {
	if _, ok := app.requireCrewspaceGroupMember(w, r, user.ID, conversationID); !ok {
		return
	}
	group, err := app.getCrewspaceGroupInfo(r.Context(), user.ID, conversationID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "gruppeninfo konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, group)
}

func (app *application) handleUpdateCrewspaceGroupInfo(
	w http.ResponseWriter,
	r *http.Request,
	user firebaseUser,
	conversationID string,
) {
	role, ok := app.requireCrewspaceGroupMember(w, r, user.ID, conversationID)
	if !ok {
		return
	}
	if role != "owner" {
		writeError(w, http.StatusForbidden, "nur die gruppenleitung darf gruppeninfos aendern")
		return
	}

	var input updateCrewspaceGroupRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.Title = strings.TrimSpace(input.Title)
	input.Info = strings.TrimSpace(input.Info)
	if input.Title == "" || len(input.Title) > 80 {
		writeError(w, http.StatusBadRequest, "gruppenname ist erforderlich und darf hoechstens 80 zeichen haben")
		return
	}
	if len(input.Info) > 1000 {
		writeError(w, http.StatusBadRequest, "gruppeninfo darf hoechstens 1000 zeichen haben")
		return
	}

	if _, err := app.db.ExecContext(
		r.Context(),
		`UPDATE crewspace_conversations SET title = $1, info = $2, updated_at = now()
		 WHERE id = $3 AND kind = 'group'`,
		input.Title,
		input.Info,
		conversationID,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "gruppeninfo konnte nicht gespeichert werden")
		return
	}
	app.writeCrewspaceGroupInfo(w, r, user.ID, conversationID)
}

func (app *application) handleAddCrewspaceGroupMember(
	w http.ResponseWriter,
	r *http.Request,
	user firebaseUser,
	conversationID string,
) {
	role, ok := app.requireCrewspaceGroupMember(w, r, user.ID, conversationID)
	if !ok {
		return
	}
	if role != "owner" {
		writeError(w, http.StatusForbidden, "nur die gruppenleitung darf mitglieder hinzufuegen")
		return
	}

	var input updateCrewspaceMemberRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.SkipperID = strings.TrimSpace(input.SkipperID)
	input.CrewRole = strings.TrimSpace(input.CrewRole)
	if input.SkipperID == "" {
		writeError(w, http.StatusBadRequest, "skipper_id fehlt")
		return
	}
	if !validCrewspaceCrewRole(input.CrewRole) {
		writeError(w, http.StatusBadRequest, "ungueltige crewrolle")
		return
	}

	var profileExists bool
	if err := app.db.QueryRowContext(
		r.Context(),
		`SELECT EXISTS (SELECT 1 FROM skipper_profiles WHERE id = $1)`,
		input.SkipperID,
	).Scan(&profileExists); err != nil {
		writeError(w, http.StatusInternalServerError, "skipper konnte nicht geprueft werden")
		return
	}
	if !profileExists {
		writeError(w, http.StatusNotFound, "skipper nicht gefunden")
		return
	}

	var memberCount int
	if err := app.db.QueryRowContext(
		r.Context(),
		`SELECT count(*) FROM crewspace_members WHERE conversation_id = $1`,
		conversationID,
	).Scan(&memberCount); err != nil {
		writeError(w, http.StatusInternalServerError, "gruppenmitglieder konnten nicht geprueft werden")
		return
	}
	if memberCount >= 50 {
		writeError(w, http.StatusConflict, "die gruppe hat bereits 50 mitglieder")
		return
	}

	result, err := app.db.ExecContext(
		r.Context(),
		`INSERT INTO crewspace_members (conversation_id, skipper_id, role, crew_role, is_on_board)
		 VALUES ($1, $2, 'member', $3, $4)
		 ON CONFLICT (conversation_id, skipper_id) DO NOTHING`,
		conversationID,
		input.SkipperID,
		input.CrewRole,
		input.IsOnBoard,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "mitglied konnte nicht hinzugefuegt werden")
		return
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		writeError(w, http.StatusConflict, "skipper ist bereits gruppenmitglied")
		return
	}
	app.touchCrewspaceConversation(r.Context(), conversationID)
	app.writeCrewspaceGroupInfo(w, r, user.ID, conversationID)
}

func (app *application) handleUpdateCrewspaceGroupMember(
	w http.ResponseWriter,
	r *http.Request,
	user firebaseUser,
	conversationID string,
	targetID string,
) {
	requesterRole, ok := app.requireCrewspaceGroupMember(w, r, user.ID, conversationID)
	if !ok {
		return
	}
	targetID = strings.TrimSpace(targetID)
	if targetID == "" {
		http.NotFound(w, r)
		return
	}

	var input updateCrewspaceMemberRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	if strings.TrimSpace(input.SkipperID) != "" && strings.TrimSpace(input.SkipperID) != targetID {
		writeError(w, http.StatusBadRequest, "skipper_id stimmt nicht mit dem pfad ueberein")
		return
	}
	input.CrewRole = strings.TrimSpace(input.CrewRole)

	var currentCrewRole string
	if err := app.db.QueryRowContext(
		r.Context(),
		`SELECT crew_role FROM crewspace_members WHERE conversation_id = $1 AND skipper_id = $2`,
		conversationID,
		targetID,
	).Scan(&currentCrewRole); errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "gruppenmitglied nicht gefunden")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "gruppenmitglied konnte nicht geprueft werden")
		return
	}

	if requesterRole != "owner" {
		if targetID != user.ID {
			writeError(w, http.StatusForbidden, "der bordstatus darf nur fuer das eigene profil geaendert werden")
			return
		}
		input.CrewRole = currentCrewRole
	} else if !validCrewspaceCrewRole(input.CrewRole) {
		writeError(w, http.StatusBadRequest, "ungueltige crewrolle")
		return
	}

	if _, err := app.db.ExecContext(
		r.Context(),
		`UPDATE crewspace_members SET crew_role = $1, is_on_board = $2
		 WHERE conversation_id = $3 AND skipper_id = $4`,
		input.CrewRole,
		input.IsOnBoard,
		conversationID,
		targetID,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "gruppenmitglied konnte nicht aktualisiert werden")
		return
	}
	app.touchCrewspaceConversation(r.Context(), conversationID)
	app.writeCrewspaceGroupInfo(w, r, user.ID, conversationID)
}

func (app *application) handleRemoveCrewspaceGroupMember(
	w http.ResponseWriter,
	r *http.Request,
	user firebaseUser,
	conversationID string,
	targetID string,
) {
	requesterRole, ok := app.requireCrewspaceGroupMember(w, r, user.ID, conversationID)
	if !ok {
		return
	}
	if requesterRole != "owner" {
		writeError(w, http.StatusForbidden, "nur die gruppenleitung darf mitglieder entfernen")
		return
	}
	targetID = strings.TrimSpace(targetID)
	var targetPermission string
	if err := app.db.QueryRowContext(
		r.Context(),
		`SELECT role FROM crewspace_members WHERE conversation_id = $1 AND skipper_id = $2`,
		conversationID,
		targetID,
	).Scan(&targetPermission); errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "gruppenmitglied nicht gefunden")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "gruppenmitglied konnte nicht geprueft werden")
		return
	}
	if targetPermission == "owner" {
		writeError(w, http.StatusBadRequest, "die gruppenleitung kann nicht als mitglied entfernt werden")
		return
	}
	if _, err := app.db.ExecContext(
		r.Context(),
		`DELETE FROM crewspace_members WHERE conversation_id = $1 AND skipper_id = $2`,
		conversationID,
		targetID,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "gruppenmitglied konnte nicht entfernt werden")
		return
	}
	app.touchCrewspaceConversation(r.Context(), conversationID)
	w.WriteHeader(http.StatusNoContent)
}

func (app *application) requireCrewspaceGroupMember(
	w http.ResponseWriter,
	r *http.Request,
	skipperID string,
	conversationID string,
) (string, bool) {
	var role string
	err := app.db.QueryRowContext(
		r.Context(),
		`SELECT cm.role
		 FROM crewspace_conversations c
		 JOIN crewspace_members cm ON cm.conversation_id = c.id
		 WHERE c.id = $1 AND c.kind = 'group' AND cm.skipper_id = $2`,
		conversationID,
		skipperID,
	).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "gruppe nicht gefunden oder kein zugriff")
		return "", false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "gruppe konnte nicht geprueft werden")
		return "", false
	}
	return role, true
}

func (app *application) getCrewspaceGroupInfo(
	ctx context.Context,
	viewerID string,
	conversationID string,
) (crewspaceGroupInfoResponse, error) {
	var group crewspaceGroupInfoResponse
	var viewerRole string
	err := app.db.QueryRowContext(
		ctx,
		`SELECT c.id, c.title, c.info, c.created_by, mine.role
		 FROM crewspace_conversations c
		 JOIN crewspace_members mine ON mine.conversation_id = c.id AND mine.skipper_id = $2
		 WHERE c.id = $1 AND c.kind = 'group'`,
		conversationID,
		viewerID,
	).Scan(&group.ID, &group.Title, &group.Info, &group.CreatedBy, &viewerRole)
	if err != nil {
		return group, err
	}
	group.CanManage = viewerRole == "owner"
	group.Members = make([]crewspaceGroupMemberResponse, 0)

	rows, err := app.db.QueryContext(
		ctx,
		`SELECT cm.skipper_id, sp.name, sp.profile_image_url, cm.role,
		        cm.crew_role, cm.is_on_board, cm.joined_at
		 FROM crewspace_members cm
		 JOIN skipper_profiles sp ON sp.id = cm.skipper_id
		 WHERE cm.conversation_id = $1
		 ORDER BY (cm.role = 'owner') DESC, cm.joined_at, lower(sp.name)`,
		conversationID,
	)
	if err != nil {
		return group, err
	}
	defer rows.Close()
	for rows.Next() {
		var member crewspaceGroupMemberResponse
		var profileImage sql.NullString
		if err := rows.Scan(
			&member.SkipperID,
			&member.Name,
			&profileImage,
			&member.PermissionRole,
			&member.CrewRole,
			&member.IsOnBoard,
			&member.JoinedAt,
		); err != nil {
			return group, err
		}
		member.ProfileImage = nullStringPtr(profileImage)
		group.Members = append(group.Members, member)
	}
	return group, rows.Err()
}

func (app *application) writeCrewspaceGroupInfo(
	w http.ResponseWriter,
	r *http.Request,
	viewerID string,
	conversationID string,
) {
	group, err := app.getCrewspaceGroupInfo(r.Context(), viewerID, conversationID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "gruppeninfo konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, group)
}

func (app *application) touchCrewspaceConversation(ctx context.Context, conversationID string) {
	_, _ = app.db.ExecContext(ctx, `UPDATE crewspace_conversations SET updated_at = now() WHERE id = $1`, conversationID)
}

func validCrewspaceCrewRole(role string) bool {
	switch role {
	case "Skipper", "Co-Skipper", "Navigation", "Wachführung", "Deck", "Sicherheit/Medizin", "Crew":
		return true
	default:
		return false
	}
}

func (app *application) handleRemoveCrewspaceConversation(
	w http.ResponseWriter,
	r *http.Request,
	user firebaseUser,
	conversationID string,
) {
	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()

	var kind string
	var role string
	if err := tx.QueryRowContext(
		r.Context(),
		`SELECT c.kind, cm.role
		FROM crewspace_conversations c
		JOIN crewspace_members cm ON cm.conversation_id = c.id
		WHERE c.id = $1 AND cm.skipper_id = $2`,
		conversationID,
		user.ID,
	).Scan(&kind, &role); errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "unterhaltung nicht gefunden")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "unterhaltung konnte nicht geprueft werden")
		return
	}

	if kind == "direct" {
		if _, err := tx.ExecContext(
			r.Context(),
			`UPDATE crewspace_members SET hidden_at = now() WHERE conversation_id = $1 AND skipper_id = $2`,
			conversationID,
			user.ID,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "chat konnte nicht geloescht werden")
			return
		}
	} else {
		if _, err := tx.ExecContext(
			r.Context(),
			`DELETE FROM crewspace_members WHERE conversation_id = $1 AND skipper_id = $2`,
			conversationID,
			user.ID,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "gruppe konnte nicht verlassen werden")
			return
		}
		if role == "owner" {
			if _, err := tx.ExecContext(
				r.Context(),
				`UPDATE crewspace_members SET role = 'owner'
				WHERE conversation_id = $1 AND skipper_id = (
					SELECT skipper_id FROM crewspace_members
					WHERE conversation_id = $1 ORDER BY joined_at, skipper_id LIMIT 1
				)`,
				conversationID,
			); err != nil {
				writeError(w, http.StatusInternalServerError, "gruppenleitung konnte nicht uebertragen werden")
				return
			}
		}
		if _, err := tx.ExecContext(
			r.Context(),
			`DELETE FROM crewspace_conversations c
			WHERE c.id = $1 AND NOT EXISTS (
				SELECT 1 FROM crewspace_members cm WHERE cm.conversation_id = c.id
			)`,
			conversationID,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "leere gruppe konnte nicht entfernt werden")
			return
		}
	}

	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "aenderung konnte nicht bestaetigt werden")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (app *application) handleCreateCrewspacePoll(w http.ResponseWriter, r *http.Request, user firebaseUser, conversationID string) {
	var input createCrewspacePollRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.Question = strings.TrimSpace(input.Question)
	input.Options = uniqueNonEmptyStrings(input.Options)
	if input.Question == "" || len(input.Question) > 240 {
		writeError(w, http.StatusBadRequest, "umfragefrage fehlt oder ist zu lang")
		return
	}
	if len(input.Options) < 2 || len(input.Options) > 10 {
		writeError(w, http.StatusBadRequest, "eine umfrage braucht 2 bis 10 antworten")
		return
	}
	for _, option := range input.Options {
		if len(option) > 120 {
			writeError(w, http.StatusBadRequest, "eine antwort ist zu lang")
			return
		}
	}
	if input.ClosesAt != nil && input.ClosesAt.Before(time.Now()) {
		writeError(w, http.StatusBadRequest, "umfrageende liegt in der vergangenheit")
		return
	}

	pollID, err := newUUID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "id konnte nicht erzeugt werden")
		return
	}
	messageID, err := newUUID()
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
	if _, err := app.prepareCrewspaceMessageWrite(r.Context(), tx, conversationID, user.ID); err != nil {
		switch {
		case errors.Is(err, errCrewspaceNotMember):
			writeError(w, http.StatusForbidden, "kein zugriff auf diese unterhaltung")
		case isChatUnavailableError(err):
			writeChatUnavailable(w)
		default:
			writeError(w, http.StatusInternalServerError, "unterhaltung konnte nicht geprueft werden")
		}
		return
	}
	if _, err := tx.ExecContext(
		r.Context(),
		`INSERT INTO crewspace_polls (id, conversation_id, creator_id, question, allows_multiple, closes_at)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		pollID,
		conversationID,
		user.ID,
		input.Question,
		input.AllowsMultiple,
		input.ClosesAt,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "umfrage konnte nicht gespeichert werden")
		return
	}
	for position, label := range input.Options {
		optionID, err := newUUID()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "antwort-id konnte nicht erzeugt werden")
			return
		}
		if _, err := tx.ExecContext(
			r.Context(),
			`INSERT INTO crewspace_poll_options (id, poll_id, label, position) VALUES ($1, $2, $3, $4)`,
			optionID,
			pollID,
			label,
			position,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "umfrageantwort konnte nicht gespeichert werden")
			return
		}
	}
	var createdAt time.Time
	if err := tx.QueryRowContext(
		r.Context(),
		`INSERT INTO crewspace_messages (id, conversation_id, sender_id, client_message_id, text, poll_id)
		VALUES ($1, $2, $3, $1, '', $4)
		RETURNING created_at`,
		messageID,
		conversationID,
		user.ID,
		pollID,
	).Scan(&createdAt); err != nil {
		if isChatUnavailableError(err) {
			writeChatUnavailable(w)
		} else {
			writeError(w, http.StatusInternalServerError, "umfragenachricht konnte nicht gespeichert werden")
		}
		return
	}
	if err := finalizeCrewspaceMessageWrite(r.Context(), tx, conversationID, createdAt); err != nil {
		writeError(w, http.StatusInternalServerError, "unterhaltung konnte nicht aktualisiert werden")
		return
	}
	if err := app.enqueueCrewspacePushOutbox(
		r.Context(),
		tx,
		messageID,
		conversationID,
		user.ID,
		"poll",
	); err != nil {
		writeError(w, http.StatusInternalServerError, "push konnte nicht vorgemerkt werden")
		return
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "umfrage konnte nicht bestaetigt werden")
		return
	}
	message, err := app.postCommitCrewspaceMessage(r.Context(), messageID, user.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "umfrage konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusCreated, message)
}

func (app *application) handleCrewspacePollRoute(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/crewspace/polls/"), "/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] != "vote" {
		http.NotFound(w, r)
		return
	}
	pollID := parts[0]
	var input voteCrewspacePollRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.OptionIDs = uniqueNonEmptyStrings(input.OptionIDs)

	var conversationID string
	var allowsMultiple bool
	var closesAt sql.NullTime
	err := app.db.QueryRowContext(
		r.Context(),
		`SELECT conversation_id, allows_multiple, closes_at FROM crewspace_polls WHERE id = $1`,
		pollID,
	).Scan(&conversationID, &allowsMultiple, &closesAt)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "umfrage nicht gefunden")
		return
	}
	if err != nil || !app.isCrewspaceMember(r.Context(), conversationID, user.ID) {
		writeError(w, http.StatusForbidden, "kein zugriff auf diese umfrage")
		return
	}
	if closesAt.Valid && time.Now().After(closesAt.Time) {
		writeError(w, http.StatusBadRequest, "diese umfrage ist beendet")
		return
	}
	if !allowsMultiple && len(input.OptionIDs) > 1 {
		writeError(w, http.StatusBadRequest, "bei dieser umfrage ist nur eine antwort erlaubt")
		return
	}

	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(r.Context(), `DELETE FROM crewspace_poll_votes WHERE poll_id = $1 AND skipper_id = $2`, pollID, user.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "alte stimme konnte nicht ersetzt werden")
		return
	}
	for _, optionID := range input.OptionIDs {
		result, err := tx.ExecContext(
			r.Context(),
			`INSERT INTO crewspace_poll_votes (poll_id, option_id, skipper_id)
			SELECT $1, id, $3 FROM crewspace_poll_options WHERE id = $2 AND poll_id = $1`,
			pollID,
			optionID,
			user.ID,
		)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "stimme konnte nicht gespeichert werden")
			return
		}
		rows, _ := result.RowsAffected()
		if rows != 1 {
			writeError(w, http.StatusBadRequest, "ungueltige umfrageantwort")
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "stimme konnte nicht bestaetigt werden")
		return
	}
	poll, err := app.getCrewspacePoll(r.Context(), pollID, user.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "umfrage konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, poll)
}

func (app *application) handleListCrewspaceMessages(w http.ResponseWriter, r *http.Request, user firebaseUser, conversationID string) {
	if !app.isCrewspaceMember(r.Context(), conversationID, user.ID) {
		writeError(w, http.StatusForbidden, "kein zugriff auf diese unterhaltung")
		return
	}
	rows, err := app.db.QueryContext(
		r.Context(),
		crewspaceMessageSelectSQL()+`
		WHERE m.conversation_id = $1
		ORDER BY m.created_at ASC, m.id ASC LIMIT 500`,
		conversationID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "nachrichten konnten nicht geladen werden")
		return
	}
	storedMessages := make([]storedCrewspaceMessage, 0)
	for rows.Next() {
		message, pollID, eventID, err := scanCrewspaceMessageRow(rows)
		if err != nil {
			rows.Close()
			writeError(w, http.StatusInternalServerError, "nachrichten konnten nicht gelesen werden")
			return
		}
		storedMessages = append(storedMessages, storedCrewspaceMessage{
			Message: message,
			PollID:  pollID,
			EventID: eventID,
		})
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		writeError(w, http.StatusInternalServerError, "nachrichten konnten nicht gelesen werden")
		return
	}
	if err := rows.Close(); err != nil {
		writeError(w, http.StatusInternalServerError, "nachrichten konnten nicht gelesen werden")
		return
	}
	messages := make([]crewspaceMessageResponse, 0, len(storedMessages))
	for _, stored := range storedMessages {
		message := stored.Message
		if err := app.hydrateCrewspaceMessage(
			r.Context(),
			&message,
			stored.PollID,
			stored.EventID,
			user.ID,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "nachrichteninhalt konnte nicht gelesen werden")
			return
		}
		messages = append(messages, message)
	}
	writeJSON(w, http.StatusOK, messages)
}

func (app *application) getCrewspaceMessage(ctx context.Context, messageID string, viewerID string) (crewspaceMessageResponse, error) {
	message, pollID, eventID, err := scanCrewspaceMessageRow(app.db.QueryRowContext(
		ctx,
		crewspaceMessageSelectSQL()+` WHERE m.id = $1`,
		messageID,
	))
	if err != nil {
		return message, err
	}
	if err := app.hydrateCrewspaceMessage(ctx, &message, pollID, eventID, viewerID); err != nil {
		return message, err
	}
	return message, nil
}

func (app *application) getCrewspacePoll(ctx context.Context, pollID string, viewerID string) (crewspacePollResponse, error) {
	var poll crewspacePollResponse
	var closesAt sql.NullTime
	err := app.db.QueryRowContext(
		ctx,
		`SELECT id, question, allows_multiple, closes_at,
			(SELECT count(*) FROM crewspace_poll_votes WHERE poll_id = $1)
		FROM crewspace_polls WHERE id = $1`,
		pollID,
	).Scan(&poll.ID, &poll.Question, &poll.AllowsMultiple, &closesAt, &poll.TotalVotes)
	if err != nil {
		return poll, err
	}
	if closesAt.Valid {
		poll.ClosesAt = &closesAt.Time
	}
	rows, err := app.db.QueryContext(
		ctx,
		`SELECT o.id, o.label, count(v.option_id),
			EXISTS (SELECT 1 FROM crewspace_poll_votes mine WHERE mine.poll_id = o.poll_id AND mine.option_id = o.id AND mine.skipper_id = $2)
		FROM crewspace_poll_options o
		LEFT JOIN crewspace_poll_votes v ON v.poll_id = o.poll_id AND v.option_id = o.id
		WHERE o.poll_id = $1
		GROUP BY o.id, o.label, o.position, o.poll_id
		ORDER BY o.position ASC`,
		pollID,
		viewerID,
	)
	if err != nil {
		return poll, err
	}
	defer rows.Close()
	poll.Options = make([]crewspacePollOptionResponse, 0)
	for rows.Next() {
		var option crewspacePollOptionResponse
		if err := rows.Scan(&option.ID, &option.Label, &option.VoteCount, &option.IsSelected); err != nil {
			return poll, err
		}
		poll.Options = append(poll.Options, option)
	}
	return poll, rows.Err()
}

func (app *application) handleCreateCrewspaceMessage(w http.ResponseWriter, r *http.Request, user firebaseUser, conversationID string) {
	var input createCrewspaceMessageRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.ClientMessageID = strings.TrimSpace(input.ClientMessageID)
	input.Text = strings.TrimSpace(input.Text)
	mediaURL := cleanOptionalURL(input.MediaURL)
	mediaType := cleanOptionalText(input.MediaType, 16)
	if input.ClientMessageID == "" {
		legacyID, err := newUUID()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "client_message_id konnte nicht erzeugt werden")
			return
		}
		input.ClientMessageID = "legacy-" + legacyID
	}
	if len(input.ClientMessageID) > 128 {
		writeError(w, http.StatusBadRequest, "client_message_id ist zu lang")
		return
	}
	if input.Text == "" && mediaURL == nil {
		writeError(w, http.StatusBadRequest, "nachricht oder medium ist erforderlich")
		return
	}
	if len(input.Text) > 4000 {
		writeError(w, http.StatusBadRequest, "nachricht ist zu lang")
		return
	}
	if mediaURL != nil && !app.isAllowedCrewspaceMediaURL(*mediaURL) {
		writeError(w, http.StatusBadRequest, "media_url hat keinen erlaubten upload-ursprung")
		return
	}
	if mediaURL != nil && (mediaType == nil || (*mediaType != "image" && *mediaType != "audio")) {
		writeError(w, http.StatusBadRequest, "media_type muss image oder audio sein")
		return
	}
	if mediaURL == nil {
		mediaType = nil
		input.MediaDuration = nil
	}
	if input.MediaDuration != nil && (*input.MediaDuration < 0 || *input.MediaDuration > 900) {
		writeError(w, http.StatusBadRequest, "audiodauer ist ungueltig")
		return
	}

	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()
	if _, err := app.prepareCrewspaceMessageWrite(r.Context(), tx, conversationID, user.ID); err != nil {
		switch {
		case errors.Is(err, errCrewspaceNotMember):
			writeError(w, http.StatusForbidden, "kein zugriff auf diese unterhaltung")
		case isChatUnavailableError(err):
			writeChatUnavailable(w)
		default:
			writeError(w, http.StatusInternalServerError, "unterhaltung konnte nicht geprueft werden")
		}
		return
	}

	messageID, err := newUUID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "id konnte nicht erzeugt werden")
		return
	}
	result, err := tx.ExecContext(
		r.Context(),
		`INSERT INTO crewspace_messages (
			id, conversation_id, sender_id, client_message_id, text,
			media_url, media_type, media_duration_seconds
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (conversation_id, sender_id, client_message_id) DO NOTHING`,
		messageID,
		conversationID,
		user.ID,
		input.ClientMessageID,
		input.Text,
		nullableArg(mediaURL),
		nullableArg(mediaType),
		nullableFloat64(input.MediaDuration),
	)
	if err != nil {
		if isChatUnavailableError(err) {
			writeChatUnavailable(w)
		} else {
			writeError(w, http.StatusInternalServerError, "nachricht konnte nicht gespeichert werden")
		}
		return
	}
	affected, err := result.RowsAffected()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "nachricht konnte nicht bestaetigt werden")
		return
	}
	created := affected == 1
	message, _, _, err := scanCrewspaceMessageRow(tx.QueryRowContext(
		r.Context(),
		crewspaceMessageSelectSQL()+`
		 WHERE m.conversation_id = $1 AND m.sender_id = $2 AND m.client_message_id = $3`,
		conversationID,
		user.ID,
		input.ClientMessageID,
	))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "nachricht konnte nicht geladen werden")
		return
	}
	if created {
		if err := finalizeCrewspaceMessageWrite(
			r.Context(),
			tx,
			conversationID,
			message.CreatedAt,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "unterhaltung konnte nicht aktualisiert werden")
			return
		}
		if err := app.enqueueCrewspacePushOutbox(
			r.Context(),
			tx,
			message.ID,
			conversationID,
			user.ID,
			crewspaceMessageType(message),
		); err != nil {
			writeError(w, http.StatusInternalServerError, "push konnte nicht vorgemerkt werden")
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "nachricht konnte nicht bestaetigt werden")
		return
	}
	if created {
		message, err = app.postCommitCrewspaceMessage(r.Context(), message.ID, user.ID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "nachricht konnte nicht geladen werden")
			return
		}
	}
	writeJSON(w, http.StatusCreated, message)
}

func (app *application) handleMarkCrewspaceRead(w http.ResponseWriter, r *http.Request, user firebaseUser, conversationID string) {
	result, err := app.db.ExecContext(
		r.Context(),
		`UPDATE crewspace_members SET last_read_at = now() WHERE conversation_id = $1 AND skipper_id = $2`,
		conversationID,
		user.ID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "lesestatus konnte nicht gespeichert werden")
		return
	}
	count, _ := result.RowsAffected()
	if count == 0 {
		writeError(w, http.StatusForbidden, "kein zugriff auf diese unterhaltung")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (app *application) handleListCrewspaceEvents(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	rows, err := app.db.QueryContext(
		r.Context(),
		`SELECT e.id, e.conversation_id, c.title, e.creator_id, sp.name, e.title, e.starts_at, e.ends_at, e.location, e.notes,
			e.attachment_url, e.attachment_name, e.attachment_content_type
		FROM crewspace_events e
		LEFT JOIN crewspace_conversations c ON c.id = e.conversation_id
		JOIN skipper_profiles sp ON sp.id = e.creator_id
		WHERE e.ends_at >= now() - interval '30 days'
			AND (
				(e.conversation_id IS NULL AND e.creator_id = $1)
				OR EXISTS (
					SELECT 1 FROM crewspace_members cm
					WHERE cm.conversation_id = e.conversation_id AND cm.skipper_id = $1
				)
			)
		ORDER BY e.starts_at ASC LIMIT 500`,
		user.ID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "termine konnten nicht geladen werden")
		return
	}
	defer rows.Close()
	events := make([]crewspaceEventResponse, 0)
	for rows.Next() {
		var event crewspaceEventResponse
		var conversationID sql.NullString
		var conversationTitle sql.NullString
		var location sql.NullString
		var notes sql.NullString
		var attachmentURL sql.NullString
		var attachmentName sql.NullString
		var attachmentType sql.NullString
		if err := rows.Scan(
			&event.ID,
			&conversationID,
			&conversationTitle,
			&event.CreatorID,
			&event.CreatorName,
			&event.Title,
			&event.StartsAt,
			&event.EndsAt,
			&location,
			&notes,
			&attachmentURL,
			&attachmentName,
			&attachmentType,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "termine konnten nicht gelesen werden")
			return
		}
		event.ConversationID = nullStringPtr(conversationID)
		event.ConversationTitle = nullStringPtr(conversationTitle)
		event.Location = nullStringPtr(location)
		event.Notes = nullStringPtr(notes)
		event.AttachmentURL = nullStringPtr(attachmentURL)
		event.AttachmentName = nullStringPtr(attachmentName)
		event.AttachmentType = nullStringPtr(attachmentType)
		events = append(events, event)
	}
	writeJSON(w, http.StatusOK, events)
}

func (app *application) handleCreateCrewspaceEvent(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input createCrewspaceEventRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.Title = strings.TrimSpace(input.Title)
	conversationID := cleanOptionalText(input.ConversationID, 128)
	location := cleanOptionalText(input.Location, 160)
	notes := cleanOptionalText(input.Notes, 1200)
	attachmentURL := cleanOptionalURL(input.AttachmentURL)
	attachmentName := cleanOptionalText(input.AttachmentName, 180)
	attachmentType := cleanOptionalText(input.AttachmentType, 160)
	if input.Title == "" || len(input.Title) > 120 || input.EndsAt.Before(input.StartsAt) {
		writeError(w, http.StatusBadRequest, "ungueltige termindaten")
		return
	}
	if attachmentURL != nil || attachmentName != nil || attachmentType != nil {
		if attachmentURL == nil || attachmentName == nil || attachmentType == nil ||
			!isHTTPURL(*attachmentURL) || !allowedCrewspaceDocumentType(strings.ToLower(*attachmentType)) {
			writeError(w, http.StatusBadRequest, "ungueltiger terminanhang")
			return
		}
	}
	eventID, err := newUUID()
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
	if conversationID != nil {
		if _, err := app.prepareCrewspaceMessageWrite(r.Context(), tx, *conversationID, user.ID); err != nil {
			switch {
			case errors.Is(err, errCrewspaceNotMember):
				writeError(w, http.StatusForbidden, "termin darf nur in eigenen unterhaltungen erstellt werden")
			case isChatUnavailableError(err):
				writeChatUnavailable(w)
			default:
				writeError(w, http.StatusInternalServerError, "unterhaltung konnte nicht geprueft werden")
			}
			return
		}
	}
	if _, err := tx.ExecContext(
		r.Context(),
		`INSERT INTO crewspace_events (
			id, conversation_id, creator_id, title, starts_at, ends_at, location, notes,
			attachment_url, attachment_name, attachment_content_type
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		eventID,
		nullableArg(conversationID),
		user.ID,
		input.Title,
		input.StartsAt,
		input.EndsAt,
		nullableArg(location),
		nullableArg(notes),
		nullableArg(attachmentURL),
		nullableArg(attachmentName),
		nullableArg(attachmentType),
	); err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht gespeichert werden")
		return
	}
	var messageID string
	if conversationID != nil {
		messageID, err = app.insertCrewspaceEventMessage(
			r.Context(),
			tx,
			eventID,
			*conversationID,
			user.ID,
		)
		if err != nil {
			if isChatUnavailableError(err) {
				writeChatUnavailable(w)
			} else {
				writeError(w, http.StatusInternalServerError, "termin konnte nicht im chat geteilt werden")
			}
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht bestaetigt werden")
		return
	}
	event, err := app.getCrewspaceEvent(r.Context(), eventID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht geladen werden")
		return
	}
	if messageID != "" {
		if _, err := app.postCommitCrewspaceMessage(r.Context(), messageID, user.ID); err != nil {
			writeError(w, http.StatusInternalServerError, "termin konnte nicht im chat geteilt werden")
			return
		}
	}
	writeJSON(w, http.StatusCreated, event)
}

func (app *application) handleCrewspaceEventRoute(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/crewspace/events/"), "/"), "/")
	if len(parts) == 1 && parts[0] != "" {
		switch r.Method {
		case http.MethodPut:
			app.handleUpdateCrewspaceEvent(w, r, user, parts[0])
		case http.MethodDelete:
			app.handleDeleteCrewspaceEvent(w, r, user, parts[0])
		default:
			http.NotFound(w, r)
		}
		return
	}
	if len(parts) != 2 || parts[0] == "" || parts[1] != "share" || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	var input shareCrewspaceEventRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	conversationID := strings.TrimSpace(input.ConversationID)
	if conversationID == "" {
		writeError(w, http.StatusForbidden, "termin darf nur in eigenen unterhaltungen geteilt werden")
		return
	}
	tx, err := app.db.BeginTx(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
		return
	}
	defer tx.Rollback()
	if _, err := app.prepareCrewspaceMessageWrite(r.Context(), tx, conversationID, user.ID); err != nil {
		switch {
		case errors.Is(err, errCrewspaceNotMember):
			writeError(w, http.StatusForbidden, "termin darf nur in eigenen unterhaltungen geteilt werden")
		case isChatUnavailableError(err):
			writeChatUnavailable(w)
		default:
			writeError(w, http.StatusInternalServerError, "unterhaltung konnte nicht geprueft werden")
		}
		return
	}
	result, err := tx.ExecContext(
		r.Context(),
		`UPDATE crewspace_events
		SET conversation_id = $1
		WHERE id = $2 AND creator_id = $3 AND conversation_id IS NULL`,
		conversationID,
		parts[0],
		user.ID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht geteilt werden")
		return
	}
	count, _ := result.RowsAffected()
	if count != 1 {
		writeError(w, http.StatusForbidden, "nur eigene private termine koennen geteilt werden")
		return
	}
	messageID, err := app.insertCrewspaceEventMessage(
		r.Context(),
		tx,
		parts[0],
		conversationID,
		user.ID,
	)
	if err != nil {
		if isChatUnavailableError(err) {
			writeChatUnavailable(w)
		} else {
			writeError(w, http.StatusInternalServerError, "termin konnte nicht im chat geteilt werden")
		}
		return
	}
	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht bestaetigt werden")
		return
	}
	if _, err := app.postCommitCrewspaceMessage(r.Context(), messageID, user.ID); err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht im chat geteilt werden")
		return
	}
	event, err := app.getCrewspaceEvent(r.Context(), parts[0])
	if err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, event)
}

func (app *application) handleUpdateCrewspaceEvent(
	w http.ResponseWriter,
	r *http.Request,
	user firebaseUser,
	eventID string,
) {
	var input createCrewspaceEventRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.Title = strings.TrimSpace(input.Title)
	conversationID := cleanOptionalText(input.ConversationID, 128)
	location := cleanOptionalText(input.Location, 160)
	notes := cleanOptionalText(input.Notes, 1200)
	attachmentURL := cleanOptionalURL(input.AttachmentURL)
	attachmentName := cleanOptionalText(input.AttachmentName, 180)
	attachmentType := cleanOptionalText(input.AttachmentType, 160)
	if input.Title == "" || len(input.Title) > 120 || input.EndsAt.Before(input.StartsAt) {
		writeError(w, http.StatusBadRequest, "ungueltige termindaten")
		return
	}
	if conversationID != nil && !app.isCrewspaceMember(r.Context(), *conversationID, user.ID) {
		writeError(w, http.StatusForbidden, "termin darf nur eigenen unterhaltungen zugeordnet werden")
		return
	}
	var currentConversationID sql.NullString
	if err := app.db.QueryRowContext(
		r.Context(),
		`SELECT conversation_id FROM crewspace_events WHERE id = $1 AND creator_id = $2`,
		eventID,
		user.ID,
	).Scan(&currentConversationID); errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusForbidden, "nur eigene termine koennen bearbeitet werden")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht geprueft werden")
		return
	}
	if currentConversationID.Valid != (conversationID != nil) ||
		(currentConversationID.Valid && currentConversationID.String != *conversationID) {
		writeError(w, http.StatusBadRequest, "die terminfreigabe kann beim bearbeiten nicht geaendert werden")
		return
	}
	if attachmentURL != nil || attachmentName != nil || attachmentType != nil {
		if attachmentURL == nil || attachmentName == nil || attachmentType == nil ||
			!isHTTPURL(*attachmentURL) || !allowedCrewspaceDocumentType(strings.ToLower(*attachmentType)) {
			writeError(w, http.StatusBadRequest, "ungueltiger terminanhang")
			return
		}
	}
	result, err := app.db.ExecContext(
		r.Context(),
		`UPDATE crewspace_events SET
			conversation_id = $1, title = $2, starts_at = $3, ends_at = $4,
			location = $5, notes = $6, attachment_url = $7, attachment_name = $8,
			attachment_content_type = $9
		WHERE id = $10 AND creator_id = $11`,
		nullableArg(conversationID),
		input.Title,
		input.StartsAt,
		input.EndsAt,
		nullableArg(location),
		nullableArg(notes),
		nullableArg(attachmentURL),
		nullableArg(attachmentName),
		nullableArg(attachmentType),
		eventID,
		user.ID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht aktualisiert werden")
		return
	}
	count, _ := result.RowsAffected()
	if count != 1 {
		writeError(w, http.StatusForbidden, "nur eigene termine koennen bearbeitet werden")
		return
	}
	event, err := app.getCrewspaceEvent(r.Context(), eventID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, event)
}

func (app *application) handleDeleteCrewspaceEvent(
	w http.ResponseWriter,
	r *http.Request,
	user firebaseUser,
	eventID string,
) {
	result, err := app.db.ExecContext(
		r.Context(),
		`DELETE FROM crewspace_events WHERE id = $1 AND creator_id = $2`,
		eventID,
		user.ID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "termin konnte nicht geloescht werden")
		return
	}
	count, _ := result.RowsAffected()
	if count != 1 {
		writeError(w, http.StatusForbidden, "nur eigene termine koennen geloescht werden")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (app *application) insertCrewspaceEventMessage(
	ctx context.Context,
	tx *sql.Tx,
	eventID string,
	conversationID string,
	senderID string,
) (string, error) {
	messageID, err := newUUID()
	if err != nil {
		return "", err
	}
	var createdAt time.Time
	if err := tx.QueryRowContext(
		ctx,
		`INSERT INTO crewspace_messages (id, conversation_id, sender_id, client_message_id, text, event_id)
		VALUES ($1, $2, $3, $1, '', $4)
		RETURNING created_at`,
		messageID,
		conversationID,
		senderID,
		eventID,
	).Scan(&createdAt); err != nil {
		return "", err
	}
	if err := finalizeCrewspaceMessageWrite(ctx, tx, conversationID, createdAt); err != nil {
		return "", err
	}
	if err := app.enqueueCrewspacePushOutbox(
		ctx,
		tx,
		messageID,
		conversationID,
		senderID,
		"event",
	); err != nil {
		return "", err
	}
	return messageID, nil
}

func (app *application) getCrewspaceEvent(ctx context.Context, eventID string) (crewspaceEventResponse, error) {
	var event crewspaceEventResponse
	var conversationID sql.NullString
	var conversationTitle sql.NullString
	var location sql.NullString
	var notes sql.NullString
	var attachmentURL sql.NullString
	var attachmentName sql.NullString
	var attachmentType sql.NullString
	err := app.db.QueryRowContext(
		ctx,
		`SELECT e.id, e.conversation_id, c.title, e.creator_id, sp.name, e.title, e.starts_at, e.ends_at, e.location, e.notes,
			e.attachment_url, e.attachment_name, e.attachment_content_type
		FROM crewspace_events e
		LEFT JOIN crewspace_conversations c ON c.id = e.conversation_id
		JOIN skipper_profiles sp ON sp.id = e.creator_id
		WHERE e.id = $1`,
		eventID,
	).Scan(
		&event.ID,
		&conversationID,
		&conversationTitle,
		&event.CreatorID,
		&event.CreatorName,
		&event.Title,
		&event.StartsAt,
		&event.EndsAt,
		&location,
		&notes,
		&attachmentURL,
		&attachmentName,
		&attachmentType,
	)
	if err != nil {
		return event, err
	}
	event.ConversationID = nullStringPtr(conversationID)
	event.ConversationTitle = nullStringPtr(conversationTitle)
	event.Location = nullStringPtr(location)
	event.Notes = nullStringPtr(notes)
	event.AttachmentURL = nullStringPtr(attachmentURL)
	event.AttachmentName = nullStringPtr(attachmentName)
	event.AttachmentType = nullStringPtr(attachmentType)
	return event, nil
}

func (app *application) listCrewspaceConversations(ctx context.Context, skipperID string) ([]crewspaceConversationResponse, error) {
	rows, err := app.db.QueryContext(ctx, crewspaceConversationSelectSQL()+` ORDER BY c.updated_at DESC LIMIT 200`, skipperID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	conversations := make([]crewspaceConversationResponse, 0)
	for rows.Next() {
		conversation, err := scanCrewspaceConversation(rows, skipperID)
		if err != nil {
			return nil, err
		}
		conversations = append(conversations, conversation)
	}
	return conversations, rows.Err()
}

func (app *application) getCrewspaceConversation(ctx context.Context, skipperID string, conversationID string) (crewspaceConversationResponse, error) {
	row := app.db.QueryRowContext(ctx, crewspaceConversationSelectSQL()+` AND c.id = $2`, skipperID, conversationID)
	return scanCrewspaceConversation(row, skipperID)
}

func crewspaceConversationSelectSQL() string {
	return `SELECT
		c.id,
		CASE WHEN c.kind = 'direct' THEN COALESCE(
			(SELECT sp.name
			 FROM crewspace_members other
			 JOIN skipper_profiles sp ON sp.id = other.skipper_id
			 WHERE other.conversation_id = c.id AND other.skipper_id <> $1
			 ORDER BY other.skipper_id
			 LIMIT 1),
			c.title
		) ELSE c.title END,
		c.kind,
		COALESCE((SELECT json_agg(cm.skipper_id ORDER BY cm.joined_at, cm.skipper_id) FROM crewspace_members cm WHERE cm.conversation_id = c.id), '[]'::json)::text,
		COALESCE((SELECT json_agg(sp.name ORDER BY cm.joined_at, cm.skipper_id) FROM crewspace_members cm JOIN skipper_profiles sp ON sp.id = cm.skipper_id WHERE cm.conversation_id = c.id), '[]'::json)::text,
		(SELECT CASE
			WHEN length(trim(m.text)) > 0 THEN m.text
			WHEN m.poll_id IS NOT NULL THEN 'Umfrage: ' || (SELECT p.question FROM crewspace_polls p WHERE p.id = m.poll_id)
			WHEN m.event_id IS NOT NULL THEN 'Termin: ' || (SELECT e.title FROM crewspace_events e WHERE e.id = m.event_id)
			WHEN m.media_type = 'image' THEN 'Foto'
			WHEN m.media_type = 'audio' THEN 'Sprachnachricht'
			ELSE ''
		END FROM crewspace_messages m WHERE m.conversation_id = c.id ORDER BY m.created_at DESC, m.id DESC LIMIT 1),
		(SELECT m.created_at FROM crewspace_messages m WHERE m.conversation_id = c.id ORDER BY m.created_at DESC, m.id DESC LIMIT 1),
		(SELECT count(*) FROM crewspace_messages m WHERE m.conversation_id = c.id AND m.sender_id <> $1 AND m.created_at > mine.last_read_at),
		CASE WHEN c.kind <> 'direct' THEN true ELSE NOT EXISTS (
			SELECT 1
			FROM crewspace_members other
			JOIN crewspace_blocks block
			  ON (block.blocker_uid = $1 AND block.blocked_uid = other.skipper_id)
			  OR (block.blocker_uid = other.skipper_id AND block.blocked_uid = $1)
			WHERE other.conversation_id = c.id AND other.skipper_id <> $1
		) END,
		c.updated_at
	FROM crewspace_conversations c
	JOIN crewspace_members mine ON mine.conversation_id = c.id AND mine.skipper_id = $1
		WHERE mine.hidden_at IS NULL`
}

type crewspaceRowScanner interface {
	Scan(...any) error
}

func scanCrewspaceConversation(row crewspaceRowScanner, _ string) (crewspaceConversationResponse, error) {
	var conversation crewspaceConversationResponse
	var memberIDsJSON string
	var memberNamesJSON string
	var lastMessage sql.NullString
	var lastMessageAt sql.NullTime
	var unread int64
	if err := row.Scan(
		&conversation.ID,
		&conversation.Title,
		&conversation.Kind,
		&memberIDsJSON,
		&memberNamesJSON,
		&lastMessage,
		&lastMessageAt,
		&unread,
		&conversation.ChatAvailable,
		&conversation.UpdatedAt,
	); err != nil {
		return conversation, err
	}
	if err := json.Unmarshal([]byte(memberIDsJSON), &conversation.MemberIDs); err != nil {
		return conversation, err
	}
	if err := json.Unmarshal([]byte(memberNamesJSON), &conversation.MemberNames); err != nil {
		return conversation, err
	}
	conversation.LastMessage = nullStringPtr(lastMessage)
	if lastMessageAt.Valid {
		value := lastMessageAt.Time
		conversation.LastMessageAt = &value
	}
	conversation.UnreadCount = int(unread)
	return conversation, nil
}

func (app *application) isCrewspaceMember(ctx context.Context, conversationID string, skipperID string) bool {
	var exists bool
	err := app.db.QueryRowContext(
		ctx,
		`SELECT EXISTS (SELECT 1 FROM crewspace_members WHERE conversation_id = $1 AND skipper_id = $2)`,
		conversationID,
		skipperID,
	).Scan(&exists)
	return err == nil && exists
}

func (app *application) requireCrewspaceUser(w http.ResponseWriter, r *http.Request) (firebaseUser, bool) {
	authorization := strings.TrimSpace(r.Header.Get("Authorization"))
	if !strings.HasPrefix(authorization, "Bearer ") {
		writeError(w, http.StatusUnauthorized, "firebase-token fehlt")
		return firebaseUser{}, false
	}
	if app.identity == nil {
		writeError(w, http.StatusServiceUnavailable, "firebase-authentifizierung ist nicht konfiguriert")
		return firebaseUser{}, false
	}
	user, err := app.identity.VerifyIDToken(
		r.Context(),
		strings.TrimSpace(strings.TrimPrefix(authorization, "Bearer ")),
	)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "firebase-token ist ungueltig oder abgelaufen")
		return firebaseUser{}, false
	}
	return user, true
}

func uniqueNonEmptyStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func removeString(values []string, target string) []string {
	result := values[:0]
	for _, value := range values {
		if value != target {
			result = append(result, value)
		}
	}
	return result
}

func nullableFloat64(value *float64) any {
	if value == nil {
		return nil
	}
	return *value
}
