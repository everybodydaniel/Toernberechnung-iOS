package main

import (
	"context"
	"database/sql"
	"errors"
	"sort"
	"strings"
	"time"
)

var (
	errCrewspaceNotMember = errors.New("crewspace membership required")
	errChatUnavailable    = errors.New("chat unavailable")
)

type crewspaceMessageWrite struct {
	ConversationID string
	Kind           string
	PeerUID        string
}

func lockCrewspacePair(ctx context.Context, tx *sql.Tx, firstUID string, secondUID string) error {
	_, err := tx.ExecContext(
		ctx,
		`SELECT pg_advisory_xact_lock(
			hashtext(LEAST($1, $2)),
			hashtext(GREATEST($1, $2))
		)`,
		firstUID,
		secondUID,
	)
	return err
}

func legacyCrewspaceDirectKey(firstUID string, secondUID string) string {
	uids := []string{firstUID, secondUID}
	sort.Strings(uids)
	return strings.Join(uids, ":")
}

func findCrewspaceDirectConversation(
	ctx context.Context,
	tx *sql.Tx,
	firstUID string,
	secondUID string,
) (string, error) {
	var conversationID string
	err := tx.QueryRowContext(
		ctx,
		`SELECT conversation.id
		 FROM crewspace_conversations conversation
		 WHERE conversation.kind = 'direct'
		   AND (
		       (
		           conversation.direct_user_low = LEAST($1, $2)
		           AND conversation.direct_user_high = GREATEST($1, $2)
		       )
		       OR (
		           (SELECT count(*) FROM crewspace_members member
		            WHERE member.conversation_id = conversation.id) = 2
		           AND EXISTS (
		               SELECT 1 FROM crewspace_members member
		               WHERE member.conversation_id = conversation.id AND member.skipper_id = $1
		           )
		           AND EXISTS (
		               SELECT 1 FROM crewspace_members member
		               WHERE member.conversation_id = conversation.id AND member.skipper_id = $2
		           )
		       )
		   )
		 ORDER BY (
		     conversation.direct_user_low = LEAST($1, $2)
		     AND conversation.direct_user_high = GREATEST($1, $2)
		 ) DESC, conversation.created_at, conversation.id
		 LIMIT 1
		 FOR UPDATE`,
		firstUID,
		secondUID,
	).Scan(&conversationID)
	return conversationID, err
}

func (app *application) prepareCrewspaceMessageWrite(
	ctx context.Context,
	tx *sql.Tx,
	conversationID string,
	senderUID string,
) (crewspaceMessageWrite, error) {
	write := crewspaceMessageWrite{ConversationID: conversationID}
	err := tx.QueryRowContext(
		ctx,
		`SELECT conversation.kind,
		        COALESCE((
		        	SELECT member.skipper_id
		        	FROM crewspace_members member
		        	WHERE member.conversation_id = conversation.id
		        	  AND member.skipper_id <> $2
		        	ORDER BY member.skipper_id
		        	LIMIT 1
		        ), '')
		 FROM crewspace_conversations conversation
		 WHERE conversation.id = $1`,
		conversationID,
		senderUID,
	).Scan(&write.Kind, &write.PeerUID)
	if errors.Is(err, sql.ErrNoRows) {
		return write, errCrewspaceNotMember
	}
	if err != nil {
		return write, err
	}
	if write.Kind == "direct" {
		if write.PeerUID == "" {
			return write, errCrewspaceNotMember
		}
		if err := lockCrewspacePair(ctx, tx, senderUID, write.PeerUID); err != nil {
			return write, err
		}
	}

	var lockedKind string
	if err := tx.QueryRowContext(
		ctx,
		`SELECT kind FROM crewspace_conversations WHERE id = $1 FOR UPDATE`,
		conversationID,
	).Scan(&lockedKind); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return write, errCrewspaceNotMember
		}
		return write, err
	}
	write.Kind = lockedKind

	var membershipUID string
	if err := tx.QueryRowContext(
		ctx,
		`SELECT skipper_id
		 FROM crewspace_members
		 WHERE conversation_id = $1 AND skipper_id = $2
		 FOR UPDATE`,
		conversationID,
		senderUID,
	).Scan(&membershipUID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return write, errCrewspaceNotMember
		}
		return write, err
	}
	if write.Kind == "direct" {
		blocked, err := app.usersHaveCrewspaceBlock(ctx, tx, senderUID, write.PeerUID)
		if err != nil {
			return write, err
		}
		if blocked {
			return write, errChatUnavailable
		}
	}
	return write, nil
}

func finalizeCrewspaceMessageWrite(
	ctx context.Context,
	tx *sql.Tx,
	conversationID string,
	createdAt time.Time,
) error {
	if _, err := tx.ExecContext(
		ctx,
		`UPDATE crewspace_conversations
		 SET updated_at = GREATEST(updated_at, $2)
		 WHERE id = $1`,
		conversationID,
		createdAt,
	); err != nil {
		return err
	}
	_, err := tx.ExecContext(
		ctx,
		`UPDATE crewspace_members SET hidden_at = NULL
		 WHERE conversation_id = $1 AND EXISTS (
		     SELECT 1 FROM crewspace_conversations
		     WHERE id = $1 AND kind = 'direct'
		 )`,
		conversationID,
	)
	return err
}

func (app *application) enqueueCrewspacePushOutbox(
	ctx context.Context,
	tx *sql.Tx,
	messageID string,
	conversationID string,
	senderUID string,
	messageType string,
) error {
	var senderName string
	if err := tx.QueryRowContext(
		ctx,
		`SELECT name FROM skipper_profiles WHERE id = $1`,
		senderUID,
	).Scan(&senderName); err != nil {
		return err
	}
	rows, err := tx.QueryContext(
		ctx,
		`SELECT skipper_id FROM crewspace_members
		 WHERE conversation_id = $1 AND skipper_id <> $2
		 ORDER BY skipper_id`,
		conversationID,
		senderUID,
	)
	if err != nil {
		return err
	}
	recipients := make([]string, 0)
	for rows.Next() {
		var recipient string
		if err := rows.Scan(&recipient); err != nil {
			rows.Close()
			return err
		}
		recipients = append(recipients, recipient)
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, recipient := range recipients {
		outboxID, err := newUUID()
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(
			ctx,
			`INSERT INTO push_outbox (
				id, conversation_id, message_id, recipient_uid, sender_name, message_type
			 ) VALUES ($1, $2, $3, $4, $5, $6)
			 ON CONFLICT (message_id, recipient_uid) DO NOTHING`,
			outboxID,
			conversationID,
			messageID,
			recipient,
			defaultName(senderName),
			messageType,
		); err != nil {
			return err
		}
	}
	return nil
}

func (app *application) postCommitCrewspaceMessage(
	ctx context.Context,
	messageID string,
	viewerUID string,
) (crewspaceMessageResponse, error) {
	message, err := app.getCrewspaceMessage(ctx, messageID, viewerUID)
	if err != nil {
		return message, err
	}
	broadcastContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	app.broadcastCrewspaceMessage(broadcastContext, message)
	cancel()
	app.wakePushOutbox()
	return message, nil
}

func isChatUnavailableError(err error) bool {
	return errors.Is(err, errChatUnavailable) || strings.Contains(err.Error(), "chat_unavailable")
}
