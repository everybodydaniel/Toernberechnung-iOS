package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type fakeFirebaseIdentity struct {
	verified firebaseUser
	users    map[string]firebaseUser
	err      error
}

type recordingPushSender struct {
	notifications []pushNotification
	invalid       []string
	err           error
}

func (sender *recordingPushSender) Send(_ context.Context, notification pushNotification) ([]string, error) {
	sender.notifications = append(sender.notifications, notification)
	return sender.invalid, sender.err
}

func (fake fakeFirebaseIdentity) VerifyIDToken(context.Context, string) (firebaseUser, error) {
	if fake.err != nil {
		return firebaseUser{}, fake.err
	}
	return fake.verified, nil
}

func (fake fakeFirebaseIdentity) LookupUser(_ context.Context, uid string) (firebaseUser, error) {
	if fake.err != nil {
		return firebaseUser{}, fake.err
	}
	user, ok := fake.users[uid]
	if !ok {
		return firebaseUser{}, errors.New("user not found")
	}
	return user, nil
}

func TestIdentityBearingMutationsRejectSpoofedSkipperID(t *testing.T) {
	app := &application{
		identity: fakeFirebaseIdentity{verified: firebaseUser{ID: "firebase-a", Name: "A"}},
	}
	tests := []struct {
		name   string
		method string
		path   string
		body   string
		call   func(http.ResponseWriter, *http.Request)
	}{
		{
			name:   "create post",
			method: http.MethodPost,
			path:   "/posts",
			body:   `{"skipper_id":"firebase-b","text":"Moin"}`,
			call:   app.handleCreatePost,
		},
		{
			name:   "delete post",
			method: http.MethodDelete,
			path:   "/posts/post-a",
			body:   `{"skipper_id":"firebase-b"}`,
			call: func(w http.ResponseWriter, r *http.Request) {
				app.handleDeletePost(w, r, "post-a")
			},
		},
		{
			name:   "like post",
			method: http.MethodPost,
			path:   "/posts/post-a/like",
			body:   `{"skipper_id":"firebase-b"}`,
			call: func(w http.ResponseWriter, r *http.Request) {
				app.handleLikePost(w, r, "post-a")
			},
		},
		{
			name:   "comment",
			method: http.MethodPost,
			path:   "/posts/post-a/comment",
			body:   `{"skipper_id":"firebase-b","text":"Moin"}`,
			call: func(w http.ResponseWriter, r *http.Request) {
				app.handleCreateComment(w, r, "post-a")
			},
		},
		{
			name:   "follow",
			method: http.MethodPost,
			path:   "/profiles/firebase-c/follow",
			body:   `{"skipper_id":"firebase-b"}`,
			call: func(w http.ResponseWriter, r *http.Request) {
				app.handleFollowMutation(w, r, "firebase-c", "follow")
			},
		},
		{
			name:   "profile body",
			method: http.MethodPut,
			path:   "/profiles/firebase-a",
			body:   `{"skipper_id":"firebase-b","name":"B","boat_type":"Jolle"}`,
			call: func(w http.ResponseWriter, r *http.Request) {
				app.handleUpdateProfile(w, r, "firebase-a")
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(test.method, test.path, strings.NewReader(test.body))
			request.Header.Set("Authorization", "Bearer valid-token")
			response := httptest.NewRecorder()

			test.call(response, request)

			if response.Code != http.StatusForbidden {
				t.Fatalf("expected status %d, got %d: %s", http.StatusForbidden, response.Code, response.Body.String())
			}
		})
	}
}

func TestCrewspaceCursorRoundTrip(t *testing.T) {
	message := crewspaceMessageResponse{
		ID:        "message/a",
		CreatedAt: time.Date(2026, 7, 25, 12, 34, 56, 789, time.FixedZone("CEST", 2*60*60)),
	}
	raw := encodeCrewspaceMessageCursor(message)
	cursor, err := decodeCrewspaceMessageCursor(raw)
	if err != nil {
		t.Fatalf("decode cursor: %v", err)
	}
	if cursor.ID != message.ID {
		t.Fatalf("expected id %q, got %q", message.ID, cursor.ID)
	}
	if !cursor.CreatedAt.Equal(message.CreatedAt) {
		t.Fatalf("expected time %s, got %s", message.CreatedAt, cursor.CreatedAt)
	}
	if _, err := decodeCrewspaceMessageCursor("not-base64"); err == nil {
		t.Fatal("invalid cursor must be rejected")
	}
}

func TestCrewspaceDeviceBaseDeleteValidatesJSONContract(t *testing.T) {
	app := &application{
		identity: fakeFirebaseIdentity{verified: firebaseUser{ID: "firebase-a"}},
	}
	request := httptest.NewRequest(
		http.MethodDelete,
		"/crewspace/devices",
		strings.NewReader(`{"installation_id":"fid-a","platform":"windows"}`),
	)
	request.Header.Set("Authorization", "Bearer valid-token")
	response := httptest.NewRecorder()
	app.handleDeleteCrewspaceDevice(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("device base DELETE status = %d, want %d: %s", response.Code, http.StatusBadRequest, response.Body.String())
	}
}

func TestCrewspaceMediaOriginFailsClosed(t *testing.T) {
	app := &application{}
	if app.isAllowedCrewspaceMediaURL("https://uploads.example/crewspace/a.jpg") {
		t.Fatal("media URL must be rejected without a configured upload origin")
	}
	app.uploadPublicOrigin = &url.URL{Scheme: "https", Host: "uploads.example"}
	if !app.isAllowedCrewspaceMediaURL("https://uploads.example/crewspace/a.jpg") {
		t.Fatal("configured upload origin should be accepted")
	}
	for _, raw := range []string{
		"http://uploads.example/crewspace/a.jpg",
		"https://evil.example/crewspace/a.jpg",
		"file:///tmp/a.jpg",
	} {
		if app.isAllowedCrewspaceMediaURL(raw) {
			t.Fatalf("unexpected allowed media URL %q", raw)
		}
	}
}

func TestRealtimeEnvelopeWireShape(t *testing.T) {
	message := crewspaceMessageResponse{ID: "message-a", ClientMessageID: "client-a"}
	event := newRealtimeEnvelope("message.created")
	event.Message = &message
	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("decode event: %v", err)
	}
	for _, key := range []string{"version", "type", "event_id", "occurred_at", "message"} {
		if _, exists := decoded[key]; !exists {
			t.Fatalf("wire envelope is missing %q: %s", key, payload)
		}
	}
	if decoded["version"] != float64(1) {
		t.Fatalf("expected protocol version 1, got %#v", decoded["version"])
	}
	if _, exists := decoded["conversation"]; exists {
		t.Fatalf("omitempty conversation must not be emitted: %s", payload)
	}
}

func TestRealtimeHubLimitsAndDropsSlowClients(t *testing.T) {
	hub := newRealtimeHub()
	clients := make([]*realtimeClient, 0, realtimeMaxConnectionsPerUser)
	done := make([]<-chan struct{}, 0, realtimeMaxConnectionsPerUser)
	for range realtimeMaxConnectionsPerUser {
		ctx, cancel := context.WithCancel(context.Background())
		client := &realtimeClient{send: make(chan realtimeEnvelope, 1), cancel: cancel}
		if !hub.register("uid", client) {
			t.Fatal("connection within limit was rejected")
		}
		clients = append(clients, client)
		done = append(done, ctx.Done())
	}
	_, cancel := context.WithCancel(context.Background())
	extra := &realtimeClient{send: make(chan realtimeEnvelope, 1), cancel: cancel}
	if hub.register("uid", extra) {
		t.Fatal("connection above per-user limit was accepted")
	}

	hub.publish([]string{"uid"}, newRealtimeEnvelope("first"))
	hub.publish([]string{"uid"}, newRealtimeEnvelope("second"))
	for _, closed := range done {
		select {
		case <-closed:
		default:
			t.Fatal("slow realtime client was not cancelled")
		}
	}
	for _, client := range clients {
		hub.unregister("uid", client)
	}
}

func TestPushPayloadDoesNotContainMessageContent(t *testing.T) {
	record := pushOutboxRecord{
		ConversationID: "conversation-a",
		MessageID:      "message-a",
		SenderName:     "Alice",
		MessageType:    "text",
	}
	notification := pushNotificationFor(record, []string{"fid-a"})
	if notification.Title != "Alice" || notification.Body != "Neue Nachricht" {
		t.Fatalf("unexpected visible notification: %#v", notification)
	}
	encoded, err := json.Marshal(notification)
	if err != nil {
		t.Fatalf("marshal notification: %v", err)
	}
	if strings.Contains(string(encoded), "secret message") {
		t.Fatal("push must not contain message content")
	}
	if notification.Data["conversation_id"] != record.ConversationID ||
		notification.Data["message_id"] != record.MessageID ||
		notification.Data["message_type"] != record.MessageType {
		t.Fatalf("unexpected push data: %#v", notification.Data)
	}
	message := firebaseMulticastMessage(notification, notification.InstallationIDs)
	if message.Notification != nil {
		t.Fatalf("top-level notification must be nil for Android account privacy: %#v", message.Notification)
	}
	if message.Android == nil || message.Android.Notification != nil ||
		message.Android.Priority != "high" {
		t.Fatalf("Android push must be high-priority data-only: %#v", message.Android)
	}
	if message.APNS == nil || message.APNS.Payload == nil ||
		message.APNS.Payload.Aps == nil || message.APNS.Payload.Aps.Alert == nil ||
		message.APNS.Payload.Aps.Alert.Title != notification.Title ||
		message.APNS.Payload.Aps.Alert.Body != notification.Body {
		t.Fatalf("APNs alert is missing sender and generic body: %#v", message.APNS)
	}
	if len(message.Data) != 3 {
		t.Fatalf("push data must contain only routing metadata: %#v", message.Data)
	}
}

func TestFirebaseInstallationIDsAreBatchedWithoutDroppingDevices(t *testing.T) {
	installationIDs := make([]string, 1201)
	for index := range installationIDs {
		installationIDs[index] = "fid-" + strconv.Itoa(index)
	}
	chunks := chunkInstallationIDs(installationIDs, firebaseMulticastBatchSize)
	if len(chunks) != 3 {
		t.Fatalf("chunk count = %d, want 3", len(chunks))
	}
	if len(chunks[0]) != 500 || len(chunks[1]) != 500 || len(chunks[2]) != 201 {
		t.Fatalf("unexpected chunk sizes: %d, %d, %d", len(chunks[0]), len(chunks[1]), len(chunks[2]))
	}
	total := 0
	for _, chunk := range chunks {
		total += len(chunk)
	}
	if total != len(installationIDs) {
		t.Fatalf("batched %d installation IDs, want %d", total, len(installationIDs))
	}
}

func TestLocalUploadSignatureBindsPathAndContentTypeAndPreventsOverwrite(t *testing.T) {
	now := time.Now().UTC()
	directory := t.TempDir()
	config := localUploadConfig{
		enabled:    true,
		directory:  directory,
		publicBase: "https://uploads.example",
		signingKey: []byte("0123456789abcdef0123456789abcdef"),
		presignTTL: 15 * time.Minute,
	}
	app := &application{localUploads: config}
	relativePath := "crewspace/2026/07/message.m4a"
	uploadURL, _, err := config.presignPut(relativePath, "audio/mp4", now)
	if err != nil {
		t.Fatalf("presign local upload: %v", err)
	}
	put := func(rawURL string, contentType string, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPut, rawURL, strings.NewReader(body))
		request.Header.Set("Content-Type", contentType)
		response := httptest.NewRecorder()
		app.handleLocalUpload(response, request)
		return response
	}
	first := put(uploadURL, "audio/mp4", "canonical audio")
	if first.Code != http.StatusCreated {
		t.Fatalf("signed upload status = %d: %s", first.Code, first.Body.String())
	}
	replay := put(uploadURL, "audio/mp4", "replacement")
	if replay.Code != http.StatusConflict {
		t.Fatalf("replay status = %d, want %d: %s", replay.Code, http.StatusConflict, replay.Body.String())
	}
	stored, err := os.ReadFile(filepath.Join(directory, filepath.FromSlash(relativePath)))
	if err != nil {
		t.Fatalf("read published upload: %v", err)
	}
	if string(stored) != "canonical audio" {
		t.Fatalf("replay overwrote upload: %q", stored)
	}
	tamperedType := put(uploadURL, "image/jpeg", "tampered")
	if tamperedType.Code != http.StatusForbidden {
		t.Fatalf("tampered content type status = %d, want %d", tamperedType.Code, http.StatusForbidden)
	}
	tamperedURL := strings.Replace(uploadURL, "message.m4a", "other.m4a", 1)
	tamperedPath := put(tamperedURL, "audio/mp4", "tampered")
	if tamperedPath.Code != http.StatusForbidden {
		t.Fatalf("tampered path status = %d, want %d", tamperedPath.Code, http.StatusForbidden)
	}
	expiredAt := now.Add(-time.Minute).Unix()
	expiredURL := config.publicBase + "/uploads/local/" + relativePath +
		"?expires=" + strconv.FormatInt(expiredAt, 10) +
		"&signature=" + config.signPut(relativePath, "audio/mp4", expiredAt)
	expired := put(expiredURL, "audio/mp4", "expired")
	if expired.Code != http.StatusForbidden {
		t.Fatalf("expired upload status = %d, want %d", expired.Code, http.StatusForbidden)
	}
}

func TestLocalUploadDownloadServesFilesOnly(t *testing.T) {
	directory := t.TempDir()
	publishedDirectory := filepath.Join(directory, "crewspace", "2026", "07")
	if err := os.MkdirAll(publishedDirectory, 0755); err != nil {
		t.Fatalf("create upload directories: %v", err)
	}
	if err := os.WriteFile(filepath.Join(publishedDirectory, "message.jpg"), []byte("image"), 0644); err != nil {
		t.Fatalf("write published upload: %v", err)
	}
	if err := os.WriteFile(filepath.Join(publishedDirectory, ".upload-partial"), []byte("partial"), 0644); err != nil {
		t.Fatalf("write partial upload: %v", err)
	}
	if err := os.Symlink(filepath.Join(publishedDirectory, "message.jpg"), filepath.Join(publishedDirectory, "link.jpg")); err != nil {
		t.Fatalf("create upload symlink: %v", err)
	}
	app := &application{localUploads: localUploadConfig{enabled: true, directory: directory}}
	get := func(path string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		response := httptest.NewRecorder()
		app.handleLocalUploadDownload(response, request)
		return response
	}
	file := get("/uploads/local/crewspace/2026/07/message.jpg")
	if file.Code != http.StatusOK || file.Body.String() != "image" {
		t.Fatalf("published file response = %d %q", file.Code, file.Body.String())
	}
	for _, path := range []string{
		"/uploads/local/crewspace/2026/07/",
		"/uploads/local/crewspace/2026/07/.upload-partial",
		"/uploads/local/crewspace/2026/07/link.jpg",
	} {
		response := get(path)
		if response.Code != http.StatusNotFound {
			t.Fatalf("%s status = %d, want %d", path, response.Code, http.StatusNotFound)
		}
	}
}

func TestCrewspaceHealthFailsClosed(t *testing.T) {
	validIdentity := fakeFirebaseIdentity{verified: firebaseUser{ID: "firebase-a"}}
	validPush := &recordingPushSender{}
	tests := []struct {
		name string
		app  application
		want int
	}{
		{
			name: "ready",
			app: application{
				identity:           validIdentity,
				pushSender:         validPush,
				publicBaseURL:      "https://api.example",
				uploadPublicOrigin: parseConfiguredOrigin("https://uploads.example"),
			},
			want: http.StatusOK,
		},
		{
			name: "firebase missing",
			app: application{
				publicBaseURL:      "https://api.example",
				uploadPublicOrigin: parseConfiguredOrigin("https://uploads.example"),
			},
			want: http.StatusServiceUnavailable,
		},
		{
			name: "http rejected by default",
			app: application{
				identity:           validIdentity,
				pushSender:         validPush,
				publicBaseURL:      "http://api.example",
				uploadPublicOrigin: parseConfiguredOrigin("http://uploads.example"),
			},
			want: http.StatusServiceUnavailable,
		},
		{
			name: "explicit nonproduction HTTP",
			app: application{
				identity:           validIdentity,
				pushSender:         validPush,
				publicBaseURL:      "http://127.0.0.1:8080",
				uploadPublicOrigin: parseConfiguredOrigin("http://127.0.0.1:8080"),
				allowInsecureHTTP:  true,
			},
			want: http.StatusOK,
		},
		{
			name: "production ignores HTTP opt in",
			app: application{
				identity:           validIdentity,
				pushSender:         validPush,
				publicBaseURL:      "http://api.example",
				uploadPublicOrigin: parseConfiguredOrigin("http://uploads.example"),
				production:         true,
				allowInsecureHTTP:  true,
			},
			want: http.StatusServiceUnavailable,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			test.app.handleHealth(response, httptest.NewRequest(http.MethodGet, "/healthz", nil))
			if response.Code != test.want {
				t.Fatalf("health status = %d, want %d: %s", response.Code, test.want, response.Body.String())
			}
		})
	}
}

func TestPushRetryDelayIsBounded(t *testing.T) {
	if got := pushRetryDelay(1); got != 2*time.Second {
		t.Fatalf("first retry delay = %s, want 2s", got)
	}
	if got := pushRetryDelay(99); got > 15*time.Minute {
		t.Fatalf("retry delay must be capped, got %s", got)
	}
}
