package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCrewspacePostgresDirectIdempotencyBlockAndPaging(t *testing.T) {
	dbURL := strings.TrimSpace(os.Getenv("TEST_DATABASE_URL"))
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL is not configured")
	}
	db := openIsolatedTestDatabase(t, dbURL)
	pushSender := &recordingPushSender{}
	app := &application{
		db: db,
		identity: fakeFirebaseIdentity{
			verified: firebaseUser{ID: "firebase-a", Name: "Alice"},
			users: map[string]firebaseUser{
				"firebase-b": {ID: "firebase-b", Name: "Bob"},
			},
		},
		realtime:           newRealtimeHub(),
		pushWake:           make(chan struct{}, 1),
		pushSender:         pushSender,
		uploadPublicOrigin: parseConfiguredOrigin("https://uploads.example"),
	}

	firstDirect := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/direct",
		`{"skipper_id":"firebase-b"}`,
		app.handleCreateCrewspaceDirect,
	)
	if firstDirect.Code != http.StatusCreated {
		t.Fatalf("create direct status = %d: %s", firstDirect.Code, firstDirect.Body.String())
	}
	var conversation crewspaceConversationResponse
	decodeRecorderJSON(t, firstDirect, &conversation)
	if conversation.ID == "" || !conversation.ChatAvailable {
		t.Fatalf("unexpected conversation: %#v", conversation)
	}

	secondDirect := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/direct",
		`{"skipper_id":"firebase-b"}`,
		app.handleCreateCrewspaceDirect,
	)
	var duplicateConversation crewspaceConversationResponse
	decodeRecorderJSON(t, secondDirect, &duplicateConversation)
	if duplicateConversation.ID != conversation.ID {
		t.Fatalf("direct dedupe returned %q, want %q", duplicateConversation.ID, conversation.ID)
	}
	if err := upsertProfile(context.Background(), db, "firebase-a", "Stale token name", nil); err != nil {
		t.Fatalf("implicit profile upsert: %v", err)
	}
	var stableName string
	if err := db.QueryRow(`SELECT name FROM skipper_profiles WHERE id = $1`, "firebase-a").Scan(&stableName); err != nil {
		t.Fatalf("load stable profile name: %v", err)
	}
	if stableName != "Alice" {
		t.Fatalf("implicit token name overwrote explicit profile name: %q", stableName)
	}
	emptyMe := performJSONRequest(
		t,
		http.MethodPut,
		"/crewspace/me",
		`{"name":""}`,
		app.handleUpdateCrewspaceMe,
	)
	if emptyMe.Code != http.StatusOK {
		t.Fatalf("empty /me status = %d: %s", emptyMe.Code, emptyMe.Body.String())
	}
	if err := db.QueryRow(`SELECT name FROM skipper_profiles WHERE id = $1`, "firebase-a").Scan(&stableName); err != nil {
		t.Fatalf("reload stable profile name: %v", err)
	}
	if stableName != "Alice" {
		t.Fatalf("empty /me overwrote profile name: %q", stableName)
	}

	legacyConversationID, err := newUUID()
	if err != nil {
		t.Fatalf("new legacy conversation id: %v", err)
	}
	if _, err := db.Exec(
		`INSERT INTO skipper_profiles (id, name) VALUES
		 ('firebase-c', 'Carol'), ('firebase-d', 'Dora')`,
	); err != nil {
		t.Fatalf("insert legacy profiles: %v", err)
	}
	if _, err := db.Exec(
		`INSERT INTO crewspace_conversations (id, title, kind, direct_key, created_by)
		 VALUES ($1, 'Legacy', 'direct', 'firebase-c:firebase-d', 'firebase-c')`,
		legacyConversationID,
	); err != nil {
		t.Fatalf("insert legacy direct conversation: %v", err)
	}
	if _, err := db.Exec(
		`INSERT INTO crewspace_members (conversation_id, skipper_id, role) VALUES
		 ($1, 'firebase-c', 'owner'), ($1, 'firebase-d', 'member')`,
		legacyConversationID,
	); err != nil {
		t.Fatalf("insert legacy direct members: %v", err)
	}
	var pairLow string
	var pairHigh string
	if err := db.QueryRow(
		`SELECT direct_user_low, direct_user_high
		 FROM crewspace_conversations WHERE id = $1`,
		legacyConversationID,
	).Scan(&pairLow, &pairHigh); err != nil {
		t.Fatalf("load migrated legacy pair: %v", err)
	}
	if pairLow != "firebase-c" || pairHigh != "firebase-d" {
		t.Fatalf("legacy pair trigger = (%q, %q)", pairLow, pairHigh)
	}
	legacyApp := *app
	legacyApp.identity = fakeFirebaseIdentity{
		verified: firebaseUser{ID: "firebase-c", Name: "Carol"},
		users: map[string]firebaseUser{
			"firebase-d": {ID: "firebase-d", Name: "Dora"},
		},
	}
	legacyDirect := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/direct",
		`{"skipper_id":"firebase-d"}`,
		legacyApp.handleCreateCrewspaceDirect,
	)
	if legacyDirect.Code != http.StatusCreated {
		t.Fatalf("reuse legacy direct status = %d: %s", legacyDirect.Code, legacyDirect.Body.String())
	}
	var reusedLegacy crewspaceConversationResponse
	decodeRecorderJSON(t, legacyDirect, &reusedLegacy)
	if reusedLegacy.ID != legacyConversationID {
		t.Fatalf("legacy direct returned %q, want %q", reusedLegacy.ID, legacyConversationID)
	}

	send := func(clientID string, text string) *httptest.ResponseRecorder {
		return performJSONRequest(
			t,
			http.MethodPost,
			"/crewspace/conversations/"+conversation.ID+"/messages",
			fmt.Sprintf(`{"client_message_id":%q,"text":%q}`, clientID, text),
			func(w http.ResponseWriter, r *http.Request) {
				app.handleCreateCrewspaceMessage(w, r, firebaseUser{ID: "firebase-a", Name: "Alice"}, conversation.ID)
			},
		)
	}
	firstMessage := send("client-1", "Moin")
	if firstMessage.Code != http.StatusCreated {
		t.Fatalf("send status = %d: %s", firstMessage.Code, firstMessage.Body.String())
	}
	var message crewspaceMessageResponse
	decodeRecorderJSON(t, firstMessage, &message)
	retry := send("client-1", "this retry body must not replace the original")
	var retriedMessage crewspaceMessageResponse
	decodeRecorderJSON(t, retry, &retriedMessage)
	if retriedMessage.ID != message.ID || retriedMessage.Text != "Moin" {
		t.Fatalf("idempotent retry changed message: first=%#v retry=%#v", message, retriedMessage)
	}
	var messageCount int
	if err := db.QueryRow(
		`SELECT count(*) FROM crewspace_messages
		 WHERE conversation_id = $1 AND sender_id = $2 AND client_message_id = $3`,
		conversation.ID,
		"firebase-a",
		"client-1",
	).Scan(&messageCount); err != nil {
		t.Fatalf("count messages: %v", err)
	}
	if messageCount != 1 {
		t.Fatalf("idempotency stored %d rows, want 1", messageCount)
	}
	var outboxCount int
	if err := db.QueryRow(`SELECT count(*) FROM push_outbox WHERE message_id = $1`, message.ID).Scan(&outboxCount); err != nil {
		t.Fatalf("count outbox: %v", err)
	}
	if outboxCount != 1 {
		t.Fatalf("message transaction stored %d outbox rows, want 1", outboxCount)
	}
	if _, err := db.Exec(
		`INSERT INTO push_installations (installation_id, skipper_id, platform)
		 VALUES ($1, $2, 'ios')`,
		"fid-b",
		"firebase-b",
	); err != nil {
		t.Fatalf("register test installation: %v", err)
	}
	if err := app.processPushOutboxBatch(context.Background()); err != nil {
		t.Fatalf("process push outbox: %v", err)
	}
	if len(pushSender.notifications) != 1 {
		t.Fatalf("push sender calls = %d, want 1", len(pushSender.notifications))
	}
	push := pushSender.notifications[0]
	if len(push.InstallationIDs) != 1 || push.InstallationIDs[0] != "fid-b" ||
		push.Title != "Alice" || push.Body != "Neue Nachricht" ||
		push.Data["message_id"] != message.ID {
		t.Fatalf("unexpected push: %#v", push)
	}
	if _, err := db.Exec(
		`INSERT INTO push_installations (installation_id, skipper_id, platform)
		 VALUES ($1, $2, 'android')`,
		"fid-a",
		"firebase-a",
	); err != nil {
		t.Fatalf("register own test installation: %v", err)
	}
	deleteDevice := performJSONRequest(
		t,
		http.MethodDelete,
		"/crewspace/devices",
		`{"installation_id":"fid-a","platform":"android"}`,
		app.handleDeleteCrewspaceDevice,
	)
	if deleteDevice.Code != http.StatusNoContent {
		t.Fatalf("device base delete status = %d: %s", deleteDevice.Code, deleteDevice.Body.String())
	}
	var ownDeviceCount int
	if err := db.QueryRow(
		`SELECT count(*) FROM push_installations
		 WHERE installation_id = 'fid-a' AND skipper_id = 'firebase-a'`,
	).Scan(&ownDeviceCount); err != nil {
		t.Fatalf("count deleted installation: %v", err)
	}
	if ownDeviceCount != 0 {
		t.Fatalf("base device DELETE left %d installations", ownDeviceCount)
	}
	if _, err := db.Exec(
		`INSERT INTO push_installations (installation_id, skipper_id, platform)
		 SELECT 'fid-d-' || value, 'firebase-d', 'ios'
		 FROM generate_series(1, 25) AS value`,
	); err != nil {
		t.Fatalf("register many test installations: %v", err)
	}
	allInstallationIDs, err := app.pushTokens(context.Background(), "firebase-d")
	if err != nil {
		t.Fatalf("load all test installations: %v", err)
	}
	if len(allInstallationIDs) != 25 {
		t.Fatalf("push token query returned %d devices, want 25", len(allInstallationIDs))
	}

	for index := 2; index <= 4; index++ {
		response := send(fmt.Sprintf("client-%d", index), fmt.Sprintf("Message %d", index))
		if response.Code != http.StatusCreated {
			t.Fatalf("send %d status = %d: %s", index, response.Code, response.Body.String())
		}
		time.Sleep(time.Millisecond)
	}
	page := performJSONRequest(
		t,
		http.MethodGet,
		"/crewspace/conversations/"+conversation.ID+"/messages/page?limit=2",
		"",
		func(w http.ResponseWriter, r *http.Request) {
			app.handleListCrewspaceMessagesPage(w, r, firebaseUser{ID: "firebase-a"}, conversation.ID)
		},
	)
	if page.Code != http.StatusOK {
		t.Fatalf("page status = %d: %s", page.Code, page.Body.String())
	}
	var pageResponse crewspaceMessagesPageResponse
	decodeRecorderJSON(t, page, &pageResponse)
	if len(pageResponse.Messages) != 2 || !pageResponse.HasMore || pageResponse.NextBeforeCursor == nil || pageResponse.NextAfterCursor == nil {
		t.Fatalf("unexpected page: %#v", pageResponse)
	}
	if pageResponse.Messages[0].CreatedAt.After(pageResponse.Messages[1].CreatedAt) {
		t.Fatalf("page messages are not canonical ascending order: %#v", pageResponse.Messages)
	}
	_, cancelRealtime := context.WithCancel(context.Background())
	realtimeClient := &realtimeClient{
		send:   make(chan realtimeEnvelope, 8),
		cancel: cancelRealtime,
	}
	if !app.realtime.register("firebase-b", realtimeClient) {
		t.Fatal("register realtime integration client")
	}
	defer app.realtime.unregister("firebase-b", realtimeClient)
	defer cancelRealtime()
	expectRealtimeMessage := func(label string, messageID string) {
		t.Helper()
		receivedTypes := make(map[string]int)
		for range 2 {
			select {
			case event := <-realtimeClient.send:
				receivedTypes[event.Type]++
				if event.Type == "message.created" &&
					(event.Message == nil || event.Message.ID != messageID) {
					t.Fatalf("%s realtime message = %#v, want %s", label, event.Message, messageID)
				}
			case <-time.After(time.Second):
				t.Fatalf("timed out waiting for %s realtime events", label)
			}
		}
		if receivedTypes["message.created"] != 1 || receivedTypes["conversation.updated"] != 1 {
			t.Fatalf("%s realtime event counts = %#v", label, receivedTypes)
		}
		select {
		case extra := <-realtimeClient.send:
			t.Fatalf("%s emitted an extra realtime event: %#v", label, extra)
		default:
		}
	}
	pollResponse := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/conversations/"+conversation.ID+"/polls",
		`{"question":"Welche Route?","options":["Nord","Sued"]}`,
		func(w http.ResponseWriter, r *http.Request) {
			app.handleCreateCrewspacePoll(w, r, firebaseUser{ID: "firebase-a"}, conversation.ID)
		},
	)
	if pollResponse.Code != http.StatusCreated {
		t.Fatalf("poll status = %d: %s", pollResponse.Code, pollResponse.Body.String())
	}
	var pollMessage crewspaceMessageResponse
	decodeRecorderJSON(t, pollResponse, &pollMessage)
	if pollMessage.Poll == nil {
		t.Fatalf("poll message is not hydrated: %#v", pollMessage)
	}
	expectRealtimeMessage("poll", pollMessage.ID)
	if err := db.QueryRow(
		`SELECT count(*) FROM push_outbox WHERE message_id = $1`,
		pollMessage.ID,
	).Scan(&outboxCount); err != nil {
		t.Fatalf("count poll outbox: %v", err)
	}
	if outboxCount != 1 {
		t.Fatalf("poll stored %d outbox rows, want 1", outboxCount)
	}

	startsAt := time.Now().UTC().Add(time.Hour)
	endsAt := startsAt.Add(time.Hour)
	eventResponse := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/events",
		fmt.Sprintf(
			`{"conversation_id":%q,"title":"Ablegen","starts_at":%q,"ends_at":%q}`,
			conversation.ID,
			startsAt.Format(time.RFC3339Nano),
			endsAt.Format(time.RFC3339Nano),
		),
		app.handleCreateCrewspaceEvent,
	)
	if eventResponse.Code != http.StatusCreated {
		t.Fatalf("event status = %d: %s", eventResponse.Code, eventResponse.Body.String())
	}
	var event crewspaceEventResponse
	decodeRecorderJSON(t, eventResponse, &event)
	var eventMessageID string
	if err := db.QueryRow(
		`SELECT id FROM crewspace_messages WHERE event_id = $1`,
		event.ID,
	).Scan(&eventMessageID); err != nil {
		t.Fatalf("load event message: %v", err)
	}
	expectRealtimeMessage("event", eventMessageID)
	app.realtime.unregister("firebase-b", realtimeClient)
	cancelRealtime()
	if err := db.QueryRow(
		`SELECT count(*) FROM push_outbox WHERE message_id = $1`,
		eventMessageID,
	).Scan(&outboxCount); err != nil {
		t.Fatalf("count event outbox: %v", err)
	}
	if outboxCount != 1 {
		t.Fatalf("event stored %d outbox rows, want 1", outboxCount)
	}

	anchorResponse := send("cursor-anchor", "Anchor")
	if anchorResponse.Code != http.StatusCreated {
		t.Fatalf("anchor send status = %d: %s", anchorResponse.Code, anchorResponse.Body.String())
	}
	var anchorMessage crewspaceMessageResponse
	decodeRecorderJSON(t, anchorResponse, &anchorMessage)

	const concurrentMessageCount = 24
	type concurrentSendResult struct {
		message crewspaceMessageResponse
		err     error
	}
	startConcurrentSends := make(chan struct{})
	results := make(chan concurrentSendResult, concurrentMessageCount)
	var sendWaitGroup sync.WaitGroup
	for index := 0; index < concurrentMessageCount; index++ {
		sendWaitGroup.Add(1)
		go func(index int) {
			defer sendWaitGroup.Done()
			<-startConcurrentSends
			response := send(
				fmt.Sprintf("concurrent-%02d", index),
				fmt.Sprintf("Concurrent %02d", index),
			)
			if response.Code != http.StatusCreated {
				results <- concurrentSendResult{
					err: fmt.Errorf("status %d: %s", response.Code, response.Body.String()),
				}
				return
			}
			var created crewspaceMessageResponse
			if err := json.Unmarshal(response.Body.Bytes(), &created); err != nil {
				results <- concurrentSendResult{err: err}
				return
			}
			results <- concurrentSendResult{message: created}
		}(index)
	}
	close(startConcurrentSends)

	cursor := encodeCrewspaceMessageCursor(anchorMessage)
	observedMessages := make([]crewspaceMessageResponse, 0, concurrentMessageCount)
	fetchDelta := func() {
		response := performJSONRequest(
			t,
			http.MethodGet,
			"/crewspace/conversations/"+conversation.ID+"/messages/page?after="+cursor+"&limit=3",
			"",
			func(w http.ResponseWriter, r *http.Request) {
				app.handleListCrewspaceMessagesPage(w, r, firebaseUser{ID: "firebase-a"}, conversation.ID)
			},
		)
		if response.Code != http.StatusOK {
			t.Fatalf("concurrent delta status = %d: %s", response.Code, response.Body.String())
		}
		var delta crewspaceMessagesPageResponse
		decodeRecorderJSON(t, response, &delta)
		observedMessages = append(observedMessages, delta.Messages...)
		if delta.NextAfterCursor != nil {
			cursor = *delta.NextAfterCursor
		}
	}
	expectedMessageIDs := make(map[string]struct{}, concurrentMessageCount)
	completed := 0
	for completed < concurrentMessageCount {
		fetchDelta()
		select {
		case result := <-results:
			if result.err != nil {
				t.Fatalf("concurrent send: %v", result.err)
			}
			expectedMessageIDs[result.message.ID] = struct{}{}
			completed++
		case <-time.After(2 * time.Millisecond):
		}
	}
	sendWaitGroup.Wait()
	for {
		before := len(observedMessages)
		fetchDelta()
		if len(observedMessages) == before {
			break
		}
	}
	observedMessageIDs := make(map[string]struct{}, len(observedMessages))
	var previousCreatedAt time.Time
	for _, observed := range observedMessages {
		if !previousCreatedAt.IsZero() && !observed.CreatedAt.After(previousCreatedAt) {
			t.Fatalf(
				"conversation timestamps are not strictly monotonic: %s then %s",
				previousCreatedAt,
				observed.CreatedAt,
			)
		}
		previousCreatedAt = observed.CreatedAt
		observedMessageIDs[observed.ID] = struct{}{}
	}
	if len(observedMessageIDs) != len(expectedMessageIDs) {
		t.Fatalf(
			"delta sync observed %d concurrent messages, want %d",
			len(observedMessageIDs),
			len(expectedMessageIDs),
		)
	}
	for messageID := range expectedMessageIDs {
		if _, exists := observedMessageIDs[messageID]; !exists {
			t.Fatalf("delta sync skipped committed message %s", messageID)
		}
	}

	if _, err := db.Exec(
		`INSERT INTO crewspace_blocks (blocker_uid, blocked_uid) VALUES ($1, $2)`,
		"firebase-b",
		"firebase-a",
	); err != nil {
		t.Fatalf("insert block: %v", err)
	}
	blockedSend := send("client-blocked", "must not be stored")
	if blockedSend.Code != http.StatusForbidden || !strings.Contains(blockedSend.Body.String(), "chat_unavailable") {
		t.Fatalf("blocked send = %d: %s", blockedSend.Code, blockedSend.Body.String())
	}
	blockedDirect := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/direct",
		`{"skipper_id":"firebase-b"}`,
		app.handleCreateCrewspaceDirect,
	)
	if blockedDirect.Code != http.StatusForbidden || !strings.Contains(blockedDirect.Body.String(), "chat_unavailable") {
		t.Fatalf("blocked direct = %d: %s", blockedDirect.Code, blockedDirect.Body.String())
	}
	blockedPoll := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/conversations/"+conversation.ID+"/polls",
		`{"question":"Nicht speichern?","options":["Ja","Nein"]}`,
		func(w http.ResponseWriter, r *http.Request) {
			app.handleCreateCrewspacePoll(w, r, firebaseUser{ID: "firebase-a"}, conversation.ID)
		},
	)
	if blockedPoll.Code != http.StatusForbidden || !strings.Contains(blockedPoll.Body.String(), "chat_unavailable") {
		t.Fatalf("blocked poll = %d: %s", blockedPoll.Code, blockedPoll.Body.String())
	}
	blockedEvent := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/events",
		fmt.Sprintf(
			`{"conversation_id":%q,"title":"Nicht speichern","starts_at":%q,"ends_at":%q}`,
			conversation.ID,
			startsAt.Format(time.RFC3339Nano),
			endsAt.Format(time.RFC3339Nano),
		),
		app.handleCreateCrewspaceEvent,
	)
	if blockedEvent.Code != http.StatusForbidden || !strings.Contains(blockedEvent.Body.String(), "chat_unavailable") {
		t.Fatalf("blocked event = %d: %s", blockedEvent.Code, blockedEvent.Body.String())
	}
	var blockedEventCount int
	if err := db.QueryRow(
		`SELECT count(*) FROM crewspace_events WHERE title = 'Nicht speichern'`,
	).Scan(&blockedEventCount); err != nil {
		t.Fatalf("count blocked events: %v", err)
	}
	if blockedEventCount != 0 {
		t.Fatalf("blocked event stored %d rows", blockedEventCount)
	}

	outsider := performJSONRequest(
		t,
		http.MethodPost,
		"/crewspace/conversations/"+conversation.ID+"/messages",
		`{"client_message_id":"outsider-1","text":"no access"}`,
		func(w http.ResponseWriter, r *http.Request) {
			app.handleCreateCrewspaceMessage(w, r, firebaseUser{ID: "firebase-c"}, conversation.ID)
		},
	)
	if outsider.Code != http.StatusForbidden {
		t.Fatalf("outsider send status = %d: %s", outsider.Code, outsider.Body.String())
	}
}

func openIsolatedTestDatabase(t *testing.T, dbURL string) *sql.DB {
	t.Helper()
	adminDB, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open postgres: %v", err)
	}
	adminDB.SetMaxOpenConns(2)
	adminDB.SetMaxIdleConns(1)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := adminDB.PingContext(ctx); err != nil {
		adminDB.Close()
		t.Fatalf("connect postgres: %v", err)
	}
	id, err := newUUID()
	if err != nil {
		adminDB.Close()
		t.Fatalf("new schema id: %v", err)
	}
	schemaName := "crewspace_test_" + strings.ReplaceAll(id, "-", "_")
	quotedSchema := `"` + schemaName + `"`
	if _, err := adminDB.ExecContext(ctx, `CREATE SCHEMA `+quotedSchema); err != nil {
		adminDB.Close()
		t.Fatalf("create isolated schema: %v", err)
	}
	isolatedURL, err := postgresURLWithSearchPath(dbURL, schemaName)
	if err != nil {
		adminDB.Close()
		t.Fatalf("configure isolated search path: %v", err)
	}
	db, err := sql.Open("pgx", isolatedURL)
	if err != nil {
		adminDB.Close()
		t.Fatalf("open isolated postgres: %v", err)
	}
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(5)
	schema, err := os.ReadFile("schema.sql")
	if err != nil {
		db.Close()
		adminDB.Close()
		t.Fatalf("read schema: %v", err)
	}
	if _, err := db.ExecContext(ctx, string(schema)); err != nil {
		db.Close()
		_, _ = adminDB.ExecContext(ctx, `DROP SCHEMA `+quotedSchema+` CASCADE`)
		adminDB.Close()
		t.Fatalf("apply isolated schema: %v", err)
	}
	t.Cleanup(func() {
		cleanupContext, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_ = db.Close()
		_, _ = adminDB.ExecContext(cleanupContext, `DROP SCHEMA `+quotedSchema+` CASCADE`)
		_ = adminDB.Close()
	})
	return db
}

func postgresURLWithSearchPath(rawURL string, schemaName string) (string, error) {
	parsed, err := url.Parse(rawURL)
	if err == nil && (parsed.Scheme == "postgres" || parsed.Scheme == "postgresql") {
		query := parsed.Query()
		query.Set("search_path", schemaName)
		query.Set("default_query_exec_mode", "simple_protocol")
		parsed.RawQuery = query.Encode()
		return parsed.String(), nil
	}
	if strings.TrimSpace(rawURL) == "" {
		return "", errors.New("database URL is empty")
	}
	return rawURL + " search_path=" + schemaName + " default_query_exec_mode=simple_protocol", nil
}

func performJSONRequest(
	t *testing.T,
	method string,
	path string,
	body string,
	handler http.HandlerFunc,
) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	request.Header.Set("Authorization", "Bearer valid-token")
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	response := httptest.NewRecorder()
	handler(response, request)
	return response
}

func decodeRecorderJSON(t *testing.T, response *httptest.ResponseRecorder, destination any) {
	t.Helper()
	if err := json.Unmarshal(response.Body.Bytes(), destination); err != nil {
		t.Fatalf("decode response %q: %v", response.Body.String(), err)
	}
}
