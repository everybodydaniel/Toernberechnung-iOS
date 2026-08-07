package main

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type updateCrewspaceMeRequest struct {
	Name string `json:"name"`
}

type crewspaceDeviceRequest struct {
	InstallationID string `json:"installation_id"`
	Platform       string `json:"platform"`
}

type crewspaceBlocksResponse struct {
	BlockedUIDs []string `json:"blocked_uids"`
}

type crewspaceMessagesPageResponse struct {
	Messages         []crewspaceMessageResponse `json:"messages"`
	NextBeforeCursor *string                    `json:"next_before_cursor"`
	NextAfterCursor  *string                    `json:"next_after_cursor"`
	HasMore          bool                       `json:"has_more"`
}

type crewspaceMessageCursor struct {
	CreatedAt time.Time `json:"created_at"`
	ID        string    `json:"id"`
}

func (app *application) handleUpdateCrewspaceMe(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input updateCrewspaceMeRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.Name = strings.TrimSpace(input.Name)
	if len(input.Name) > 80 {
		writeError(w, http.StatusBadRequest, "name ist zu lang")
		return
	}
	var err error
	if input.Name == "" {
		err = upsertProfile(r.Context(), app.db, user.ID, user.Name, nil)
	} else {
		_, err = app.db.ExecContext(
			r.Context(),
			`INSERT INTO skipper_profiles (id, name)
			 VALUES ($1, $2)
			 ON CONFLICT (id) DO UPDATE SET
			    name = EXCLUDED.name,
			    updated_at = now()`,
			user.ID,
			input.Name,
		)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht gespeichert werden")
		return
	}
	profile, err := app.getCrewspaceSkipper(r.Context(), user.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht geladen werden")
		return
	}
	writeJSON(w, http.StatusOK, profile)
}

func (app *application) handlePutCrewspaceDevice(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var input crewspaceDeviceRequest
	if err := readJSON(w, r, &input); err != nil {
		writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
		return
	}
	input.InstallationID = strings.TrimSpace(input.InstallationID)
	input.Platform = strings.ToLower(strings.TrimSpace(input.Platform))
	if input.InstallationID == "" || len(input.InstallationID) > 4096 {
		writeError(w, http.StatusBadRequest, "installation_id ist ungueltig")
		return
	}
	if input.Platform != "android" && input.Platform != "ios" {
		writeError(w, http.StatusBadRequest, "platform muss android oder ios sein")
		return
	}
	if err := upsertProfile(r.Context(), app.db, user.ID, user.Name, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "profil konnte nicht vorbereitet werden")
		return
	}
	if _, err := app.db.ExecContext(
		r.Context(),
		`INSERT INTO push_installations (installation_id, skipper_id, platform)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (installation_id) DO UPDATE SET
		    skipper_id = EXCLUDED.skipper_id,
		    platform = EXCLUDED.platform,
		    updated_at = now()`,
		input.InstallationID,
		user.ID,
		input.Platform,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "geraet konnte nicht registriert werden")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (app *application) handleDeleteCrewspaceDevice(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	var installationID string
	if strings.TrimSuffix(r.URL.Path, "/") == "/crewspace/devices" {
		var input crewspaceDeviceRequest
		if err := readJSON(w, r, &input); err != nil {
			writeError(w, http.StatusBadRequest, "ungueltige JSON-Anfrage")
			return
		}
		installationID = strings.TrimSpace(input.InstallationID)
		input.Platform = strings.ToLower(strings.TrimSpace(input.Platform))
		if input.Platform != "" && input.Platform != "android" && input.Platform != "ios" {
			writeError(w, http.StatusBadRequest, "platform muss android oder ios sein")
			return
		}
	} else {
		rawID := strings.TrimPrefix(r.URL.EscapedPath(), "/crewspace/devices/")
		decodedID, err := url.PathUnescape(rawID)
		if err != nil || strings.Contains(decodedID, "/") {
			http.NotFound(w, r)
			return
		}
		installationID = strings.TrimSpace(decodedID)
	}
	if installationID == "" || len(installationID) > 4096 {
		writeError(w, http.StatusBadRequest, "installation_id ist ungueltig")
		return
	}
	if _, err := app.db.ExecContext(
		r.Context(),
		`DELETE FROM push_installations WHERE installation_id = $1 AND skipper_id = $2`,
		installationID,
		user.ID,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "geraet konnte nicht entfernt werden")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (app *application) handleListCrewspaceBlocks(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	rows, err := app.db.QueryContext(
		r.Context(),
		`SELECT blocked_uid FROM crewspace_blocks WHERE blocker_uid = $1 ORDER BY blocked_uid`,
		user.ID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "blockierungen konnten nicht geladen werden")
		return
	}
	defer rows.Close()
	blocked := make([]string, 0)
	for rows.Next() {
		var uid string
		if err := rows.Scan(&uid); err != nil {
			writeError(w, http.StatusInternalServerError, "blockierungen konnten nicht gelesen werden")
			return
		}
		blocked = append(blocked, uid)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, "blockierungen konnten nicht gelesen werden")
		return
	}
	writeJSON(w, http.StatusOK, crewspaceBlocksResponse{BlockedUIDs: blocked})
}

func (app *application) handleCrewspaceBlockRoute(w http.ResponseWriter, r *http.Request) {
	user, ok := app.requireCrewspaceUser(w, r)
	if !ok {
		return
	}
	rawUID := strings.TrimPrefix(r.URL.EscapedPath(), "/crewspace/blocks/")
	targetUID, err := url.PathUnescape(rawUID)
	targetUID = strings.TrimSpace(targetUID)
	if err != nil || targetUID == "" || strings.Contains(targetUID, "/") {
		http.NotFound(w, r)
		return
	}
	if targetUID == user.ID {
		writeError(w, http.StatusBadRequest, "das eigene profil kann nicht blockiert werden")
		return
	}

	switch r.Method {
	case http.MethodPut:
		if app.identity == nil {
			writeError(w, http.StatusServiceUnavailable, "firebase-authentifizierung ist nicht konfiguriert")
			return
		}
		target, err := app.identity.LookupUser(r.Context(), targetUID)
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
			writeError(w, http.StatusInternalServerError, "blockierung konnte nicht gesperrt werden")
			return
		}
		if err := upsertProfile(r.Context(), tx, user.ID, user.Name, nil); err != nil {
			writeError(w, http.StatusInternalServerError, "eigenes profil konnte nicht vorbereitet werden")
			return
		}
		if err := upsertProfile(r.Context(), tx, target.ID, target.Name, nil); err != nil {
			writeError(w, http.StatusInternalServerError, "zielprofil konnte nicht vorbereitet werden")
			return
		}
		if _, err := tx.ExecContext(
			r.Context(),
			`INSERT INTO crewspace_blocks (blocker_uid, blocked_uid)
			 VALUES ($1, $2) ON CONFLICT DO NOTHING`,
			user.ID,
			target.ID,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "blockierung konnte nicht gespeichert werden")
			return
		}
		if err := tx.Commit(); err != nil {
			writeError(w, http.StatusInternalServerError, "blockierung konnte nicht bestaetigt werden")
			return
		}
		broadcastContext, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
		app.broadcastDirectConversationState(broadcastContext, user.ID, target.ID)
		cancel()
		w.WriteHeader(http.StatusNoContent)
	case http.MethodDelete:
		tx, err := app.db.BeginTx(r.Context(), nil)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "datenbank nicht verfuegbar")
			return
		}
		defer tx.Rollback()
		if err := lockCrewspacePair(r.Context(), tx, user.ID, targetUID); err != nil {
			writeError(w, http.StatusInternalServerError, "blockierung konnte nicht gesperrt werden")
			return
		}
		if _, err := tx.ExecContext(
			r.Context(),
			`DELETE FROM crewspace_blocks WHERE blocker_uid = $1 AND blocked_uid = $2`,
			user.ID,
			targetUID,
		); err != nil {
			writeError(w, http.StatusInternalServerError, "blockierung konnte nicht entfernt werden")
			return
		}
		if err := tx.Commit(); err != nil {
			writeError(w, http.StatusInternalServerError, "blockierung konnte nicht bestaetigt werden")
			return
		}
		broadcastContext, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
		app.broadcastDirectConversationState(broadcastContext, user.ID, targetUID)
		cancel()
		w.WriteHeader(http.StatusNoContent)
	default:
		http.NotFound(w, r)
	}
}

func (app *application) getCrewspaceSkipper(ctx context.Context, uid string) (crewspaceSkipperResponse, error) {
	var skipper crewspaceSkipperResponse
	var homeHarbour sql.NullString
	var bio sql.NullString
	var profileImage sql.NullString
	err := app.db.QueryRowContext(
		ctx,
		`SELECT id, name, boat_type, home_harbour, bio, profile_image_url
		 FROM skipper_profiles WHERE id = $1`,
		uid,
	).Scan(&skipper.ID, &skipper.Name, &skipper.BoatType, &homeHarbour, &bio, &profileImage)
	if err != nil {
		return skipper, err
	}
	skipper.HomeHarbour = nullStringPtr(homeHarbour)
	skipper.Bio = nullStringPtr(bio)
	skipper.ProfileImageURL = nullStringPtr(profileImage)
	return skipper, nil
}

func (app *application) usersHaveCrewspaceBlock(ctx context.Context, runner dbRunner, firstUID string, secondUID string) (bool, error) {
	var blocked bool
	err := runner.QueryRowContext(
		ctx,
		`SELECT EXISTS (
			SELECT 1 FROM crewspace_blocks
			WHERE (blocker_uid = $1 AND blocked_uid = $2)
			   OR (blocker_uid = $2 AND blocked_uid = $1)
		)`,
		firstUID,
		secondUID,
	).Scan(&blocked)
	return blocked, err
}

func (app *application) isDirectConversationBlocked(ctx context.Context, runner dbRunner, conversationID string, senderUID string) (bool, error) {
	var blocked bool
	err := runner.QueryRowContext(
		ctx,
		`SELECT EXISTS (
			SELECT 1
			FROM crewspace_conversations conversation
			JOIN crewspace_members other
			  ON other.conversation_id = conversation.id AND other.skipper_id <> $2
			JOIN crewspace_blocks block
			  ON (block.blocker_uid = $2 AND block.blocked_uid = other.skipper_id)
			  OR (block.blocker_uid = other.skipper_id AND block.blocked_uid = $2)
			WHERE conversation.id = $1 AND conversation.kind = 'direct'
		)`,
		conversationID,
		senderUID,
	).Scan(&blocked)
	return blocked, err
}

func writeChatUnavailable(w http.ResponseWriter) {
	writeError(w, http.StatusForbidden, "chat_unavailable")
}

func parseConfiguredOrigin(raw string) *url.URL {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		slog.Warn("invalid UPLOAD_PUBLIC_ORIGIN; media URL restriction disabled", "origin", raw)
		return nil
	}
	parsed.Path = ""
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed
}

func configuredUploadOrigin(values ...string) *url.URL {
	for _, value := range values {
		if strings.TrimSpace(value) == "" {
			continue
		}
		return parseConfiguredOrigin(value)
	}
	return nil
}

func (app *application) isAllowedCrewspaceMediaURL(raw string) bool {
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
		return false
	}
	if app.uploadPublicOrigin == nil {
		return false
	}
	return strings.EqualFold(parsed.Scheme, app.uploadPublicOrigin.Scheme) &&
		strings.EqualFold(parsed.Host, app.uploadPublicOrigin.Host)
}

func encodeCrewspaceMessageCursor(message crewspaceMessageResponse) string {
	payload, _ := json.Marshal(crewspaceMessageCursor{
		CreatedAt: message.CreatedAt.UTC(),
		ID:        message.ID,
	})
	return base64.RawURLEncoding.EncodeToString(payload)
}

func decodeCrewspaceMessageCursor(raw string) (crewspaceMessageCursor, error) {
	var cursor crewspaceMessageCursor
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(raw))
	if err != nil {
		return cursor, err
	}
	if err := json.Unmarshal(payload, &cursor); err != nil {
		return cursor, err
	}
	cursor.ID = strings.TrimSpace(cursor.ID)
	if cursor.ID == "" || cursor.CreatedAt.IsZero() {
		return cursor, errors.New("invalid cursor")
	}
	cursor.CreatedAt = cursor.CreatedAt.UTC()
	return cursor, nil
}

func (app *application) handleListCrewspaceMessagesPage(w http.ResponseWriter, r *http.Request, user firebaseUser, conversationID string) {
	if !app.isCrewspaceMember(r.Context(), conversationID, user.ID) {
		writeError(w, http.StatusForbidden, "kein zugriff auf diese unterhaltung")
		return
	}
	beforeRaw := strings.TrimSpace(r.URL.Query().Get("before"))
	afterRaw := strings.TrimSpace(r.URL.Query().Get("after"))
	if beforeRaw != "" && afterRaw != "" {
		writeError(w, http.StatusBadRequest, "before und after duerfen nicht kombiniert werden")
		return
	}
	limit := 100
	if rawLimit := strings.TrimSpace(r.URL.Query().Get("limit")); rawLimit != "" {
		parsed, err := strconv.Atoi(rawLimit)
		if err != nil || parsed < 1 || parsed > 200 {
			writeError(w, http.StatusBadRequest, "limit muss zwischen 1 und 200 liegen")
			return
		}
		limit = parsed
	}

	orderDescending := afterRaw == ""
	query := crewspaceMessageSelectSQL() + ` WHERE m.conversation_id = $1`
	args := []any{conversationID}
	if beforeRaw != "" {
		cursor, err := decodeCrewspaceMessageCursor(beforeRaw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "before-cursor ist ungueltig")
			return
		}
		query += ` AND (m.created_at, m.id) < ($2, $3)`
		args = append(args, cursor.CreatedAt, cursor.ID)
	} else if afterRaw != "" {
		cursor, err := decodeCrewspaceMessageCursor(afterRaw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "after-cursor ist ungueltig")
			return
		}
		query += ` AND (m.created_at, m.id) > ($2, $3)`
		args = append(args, cursor.CreatedAt, cursor.ID)
		orderDescending = false
	}
	if orderDescending {
		query += ` ORDER BY m.created_at DESC, m.id DESC`
	} else {
		query += ` ORDER BY m.created_at ASC, m.id ASC`
	}
	args = append(args, limit+1)
	query += ` LIMIT $` + strconv.Itoa(len(args))

	rows, err := app.db.QueryContext(r.Context(), query, args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "nachrichten konnten nicht geladen werden")
		return
	}
	storedMessages := make([]storedCrewspaceMessage, 0, limit+1)
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
	hasMore := len(messages) > limit
	if hasMore {
		messages = messages[:limit]
	}
	if orderDescending {
		for left, right := 0, len(messages)-1; left < right; left, right = left+1, right-1 {
			messages[left], messages[right] = messages[right], messages[left]
		}
	}

	response := crewspaceMessagesPageResponse{Messages: messages, HasMore: hasMore}
	if len(messages) > 0 {
		if hasMore && afterRaw == "" {
			cursor := encodeCrewspaceMessageCursor(messages[0])
			response.NextBeforeCursor = &cursor
		}
		cursor := encodeCrewspaceMessageCursor(messages[len(messages)-1])
		response.NextAfterCursor = &cursor
	} else if afterRaw != "" {
		response.NextAfterCursor = &afterRaw
	}
	writeJSON(w, http.StatusOK, response)
}

func crewspaceMessageSelectSQL() string {
	return `SELECT m.id, m.conversation_id, m.sender_id, sp.name, m.client_message_id, m.text,
		m.media_url, m.media_type, m.media_duration_seconds, m.poll_id, m.event_id, m.created_at
		FROM crewspace_messages m
		JOIN skipper_profiles sp ON sp.id = m.sender_id`
}

func scanCrewspaceMessageRow(scanner crewspaceRowScanner) (crewspaceMessageResponse, sql.NullString, sql.NullString, error) {
	var message crewspaceMessageResponse
	var mediaURL sql.NullString
	var mediaType sql.NullString
	var mediaDuration sql.NullFloat64
	var pollID sql.NullString
	var eventID sql.NullString
	err := scanner.Scan(
		&message.ID,
		&message.ConversationID,
		&message.SenderID,
		&message.SenderName,
		&message.ClientMessageID,
		&message.Text,
		&mediaURL,
		&mediaType,
		&mediaDuration,
		&pollID,
		&eventID,
		&message.CreatedAt,
	)
	if err != nil {
		return message, pollID, eventID, err
	}
	message.MediaURL = nullStringPtr(mediaURL)
	message.MediaType = nullStringPtr(mediaType)
	if mediaDuration.Valid {
		message.MediaDuration = &mediaDuration.Float64
	}
	return message, pollID, eventID, nil
}

func (app *application) hydrateCrewspaceMessage(
	ctx context.Context,
	message *crewspaceMessageResponse,
	pollID sql.NullString,
	eventID sql.NullString,
	viewerID string,
) error {
	if pollID.Valid {
		poll, err := app.getCrewspacePoll(ctx, pollID.String, viewerID)
		if err != nil {
			return err
		}
		message.Poll = &poll
	}
	if eventID.Valid {
		event, err := app.getCrewspaceEvent(ctx, eventID.String)
		if err != nil {
			return err
		}
		message.Event = &event
	}
	return nil
}

func (app *application) broadcastCrewspaceMessage(ctx context.Context, message crewspaceMessageResponse) {
	if app.realtime == nil {
		return
	}
	rows, err := app.db.QueryContext(
		ctx,
		`SELECT skipper_id FROM crewspace_members WHERE conversation_id = $1`,
		message.ConversationID,
	)
	if err != nil {
		slog.Error("load realtime recipients", "error", err)
		return
	}
	recipients := make([]string, 0)
	for rows.Next() {
		var uid string
		if err := rows.Scan(&uid); err != nil {
			rows.Close()
			slog.Error("read realtime recipient", "error", err)
			return
		}
		recipients = append(recipients, uid)
	}
	if err := rows.Close(); err != nil {
		slog.Error("close realtime recipients", "error", err)
		return
	}
	for _, uid := range recipients {
		messageEvent := newRealtimeEnvelope("message.created")
		messageEvent.Message = &message
		app.realtime.publish([]string{uid}, messageEvent)

		conversation, err := app.getCrewspaceConversation(ctx, uid, message.ConversationID)
		if err != nil {
			continue
		}
		conversationEvent := newRealtimeEnvelope("conversation.updated")
		conversationEvent.Conversation = &conversation
		app.realtime.publish([]string{uid}, conversationEvent)
	}
}

func (app *application) broadcastDirectConversationState(ctx context.Context, firstUID string, secondUID string) {
	if app.realtime == nil {
		return
	}
	rows, err := app.db.QueryContext(
		ctx,
		`SELECT conversation.id
		 FROM crewspace_conversations conversation
		 WHERE conversation.kind = 'direct'
		   AND EXISTS (
		       SELECT 1 FROM crewspace_members
		       WHERE conversation_id = conversation.id AND skipper_id = $1
		   )
		   AND EXISTS (
		       SELECT 1 FROM crewspace_members
		       WHERE conversation_id = conversation.id AND skipper_id = $2
		   )`,
		firstUID,
		secondUID,
	)
	if err != nil {
		slog.Error("load changed direct conversations", "error", err)
		return
	}
	conversationIDs := make([]string, 0)
	for rows.Next() {
		var conversationID string
		if err := rows.Scan(&conversationID); err != nil {
			rows.Close()
			slog.Error("read changed direct conversation", "error", err)
			return
		}
		conversationIDs = append(conversationIDs, conversationID)
	}
	if err := rows.Close(); err != nil {
		slog.Error("close changed direct conversations", "error", err)
		return
	}
	for _, conversationID := range conversationIDs {
		for _, uid := range []string{firstUID, secondUID} {
			conversation, err := app.getCrewspaceConversation(ctx, uid, conversationID)
			if err != nil {
				continue
			}
			event := newRealtimeEnvelope("conversation.updated")
			event.Conversation = &conversation
			app.realtime.publish([]string{uid}, event)
		}
	}
}

func crewspaceMessageType(message crewspaceMessageResponse) string {
	switch {
	case message.Poll != nil:
		return "poll"
	case message.Event != nil:
		return "event"
	case message.MediaType != nil && *message.MediaType == "image":
		return "image"
	case message.MediaType != nil && *message.MediaType == "audio":
		return "audio"
	default:
		return "text"
	}
}
