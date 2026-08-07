package main

import (
	"context"
	"log/slog"
	"math"
	"strings"
	"time"
)

type pushOutboxRecord struct {
	ID             string
	ConversationID string
	MessageID      string
	RecipientUID   string
	SenderName     string
	MessageType    string
	Attempts       int
}

func (app *application) runPushOutbox(ctx context.Context) {
	if app.pushSender == nil {
		return
	}
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		if err := app.processPushOutboxBatch(ctx); err != nil && ctx.Err() == nil {
			slog.Error("process push outbox", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-app.pushWake:
		}
	}
}

func (app *application) wakePushOutbox() {
	if app.pushSender == nil {
		return
	}
	select {
	case app.pushWake <- struct{}{}:
	default:
	}
}

func (app *application) processPushOutboxBatch(ctx context.Context) error {
	rows, err := app.db.QueryContext(
		ctx,
		`SELECT id, conversation_id, message_id, recipient_uid, sender_name, message_type, attempts
		 FROM push_outbox
		 WHERE processed_at IS NULL AND next_attempt_at <= now()
		 ORDER BY created_at
		 LIMIT 50`,
	)
	if err != nil {
		return err
	}
	records := make([]pushOutboxRecord, 0, 50)
	for rows.Next() {
		var record pushOutboxRecord
		if err := rows.Scan(
			&record.ID,
			&record.ConversationID,
			&record.MessageID,
			&record.RecipientUID,
			&record.SenderName,
			&record.MessageType,
			&record.Attempts,
		); err != nil {
			rows.Close()
			return err
		}
		records = append(records, record)
	}
	if err := rows.Close(); err != nil {
		return err
	}

	for _, record := range records {
		if err := app.processPushOutboxRecord(ctx, record); err != nil {
			return err
		}
	}
	return nil
}

func (app *application) processPushOutboxRecord(ctx context.Context, record pushOutboxRecord) error {
	tokens, err := app.pushTokens(ctx, record.RecipientUID)
	if err != nil {
		return app.deferPushOutbox(ctx, record, err)
	}
	if len(tokens) == 0 {
		_, err := app.db.ExecContext(
			ctx,
			`UPDATE push_outbox SET processed_at = now(), last_error = NULL WHERE id = $1`,
			record.ID,
		)
		return err
	}

	invalid, sendErr := app.pushSender.Send(ctx, pushNotificationFor(record, tokens))
	for _, installationID := range invalid {
		if _, err := app.db.ExecContext(
			ctx,
			`DELETE FROM push_installations WHERE installation_id = $1`,
			installationID,
		); err != nil {
			return err
		}
	}
	if sendErr != nil {
		return app.deferPushOutbox(ctx, record, sendErr)
	}
	_, err = app.db.ExecContext(
		ctx,
		`UPDATE push_outbox SET processed_at = now(), last_error = NULL WHERE id = $1`,
		record.ID,
	)
	return err
}

func (app *application) pushTokens(ctx context.Context, uid string) ([]string, error) {
	rows, err := app.db.QueryContext(
		ctx,
		`SELECT installation_id FROM push_installations
		 WHERE skipper_id = $1 ORDER BY updated_at DESC`,
		uid,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	tokens := make([]string, 0)
	for rows.Next() {
		var token string
		if err := rows.Scan(&token); err != nil {
			return nil, err
		}
		tokens = append(tokens, token)
	}
	return tokens, rows.Err()
}

func (app *application) deferPushOutbox(ctx context.Context, record pushOutboxRecord, sendErr error) error {
	attempts := record.Attempts + 1
	delay := pushRetryDelay(attempts)
	errorText := strings.TrimSpace(sendErr.Error())
	if len(errorText) > 1000 {
		errorText = errorText[:1000]
	}
	_, err := app.db.ExecContext(
		ctx,
		`UPDATE push_outbox
		 SET attempts = $2, next_attempt_at = now() + ($3 * interval '1 second'), last_error = $4
		 WHERE id = $1`,
		record.ID,
		attempts,
		int(delay/time.Second),
		errorText,
	)
	return err
}

func pushRetryDelay(attempts int) time.Duration {
	if attempts < 1 {
		attempts = 1
	}
	seconds := math.Pow(2, float64(min(attempts, 9)))
	delay := time.Duration(seconds) * time.Second
	if delay > 15*time.Minute {
		return 15 * time.Minute
	}
	return delay
}

func pushNotificationFor(record pushOutboxRecord, tokens []string) pushNotification {
	return pushNotification{
		InstallationIDs: tokens,
		Title:           defaultName(record.SenderName),
		Body:            "Neue Nachricht",
		Data: map[string]string{
			"conversation_id": record.ConversationID,
			"message_id":      record.MessageID,
			"message_type":    record.MessageType,
		},
	}
}
