package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net"
	"net/http"
	netmail "net/mail"
	"net/textproto"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/emersion/go-imap"
	"github.com/emersion/go-imap/client"
)

const defaultELWISRegion = "Deutschland.Nordsee.Ostfriesische Inseln"

type elwisMailboxConfig struct {
	enabled        bool
	address        string
	username       string
	password       string
	mailbox        string
	region         string
	allowedSenders []string
	pollInterval   time.Duration
}

type maritimeNotice struct {
	ID               string                     `json:"id"`
	BFSNumber        string                     `json:"bfs_number"`
	IsTemporary      bool                       `json:"is_temporary"`
	Publisher        string                     `json:"publisher"`
	Title            string                     `json:"title"`
	RegionPath       string                     `json:"region_path"`
	Location         *string                    `json:"location"`
	Body             string                     `json:"body,omitempty"`
	PublishedAt      *time.Time                 `json:"published_at"`
	ValidFrom        *time.Time                 `json:"valid_from"`
	ValidUntil       *time.Time                 `json:"valid_until"`
	PublicationState string                     `json:"publication_state"`
	Revision         int                        `json:"revision"`
	UpdatedAt        time.Time                  `json:"updated_at"`
	SourceURL        *string                    `json:"source_url"`
	ChartReferences  []string                   `json:"chart_references,omitempty"`
	Coordinates      []maritimeNoticeCoordinate `json:"coordinates,omitempty"`
	PreviousNotices  []string                   `json:"previous_notices,omitempty"`
	ParseStatus      string                     `json:"parse_status"`
	ContentHash      string                     `json:"-"`
	MessageID        string                     `json:"-"`
}

type maritimeNoticeCoordinate struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Label     *string `json:"label"`
}

type maritimeNoticeListResponse struct {
	Notices      []maritimeNotice `json:"notices"`
	NextCursor   *string          `json:"next_cursor"`
	LastIngested *time.Time       `json:"last_ingested_at"`
	IsStale      bool             `json:"is_stale"`
}

type parsedELWISMail struct {
	notice maritimeNotice
	sender string
}

var (
	bfsNumberPattern  = regexp.MustCompile(`(?i)\bBfS\s*(\(T\))?\s*[-:]?\s*([0-9]{1,5})\s*/\s*([0-9]{2,4})\b`)
	htmlTagPattern    = regexp.MustCompile(`(?s)<[^>]+>`)
	multiBlankPattern = regexp.MustCompile(`\n{3,}`)
	spacePattern      = regexp.MustCompile(`[ \t]+`)
	urlPattern        = regexp.MustCompile(`https?://[^\s<>\"]+`)
	chartPattern      = regexp.MustCompile(`(?im)^(?:Seekarte|Karte|Chart|ENC)\s*:?\s*(.+)$`)
	previousPattern   = regexp.MustCompile(`(?im)^(?:Bezug|Vorherige Meldung|ersetzt)\s*:?\s*(.+)$`)
	locationPattern   = regexp.MustCompile(`(?im)^(?:Ort|Gebiet|Fahrwasser|Örtlichkeit)\s*:?\s*(.+)$`)
	publisherPattern  = regexp.MustCompile(`(?im)^(?:Herausgeber|Dienststelle)\s*:?\s*(.+)$`)
	validFromPattern  = regexp.MustCompile(`(?im)^(?:Gültig(?:keit)?\s*(?:von|ab)|Beginn)\s*:?\s*(.+)$`)
	validUntilPattern = regexp.MustCompile(`(?im)^(?:Gültig(?:keit)?\s*(?:bis|Ende)|Ende)\s*:?\s*(.+)$`)
	coordinatePattern = regexp.MustCompile(`(?i)(5[2-5](?:[.,][0-9]+)?)\s*[°]?\s*[Nn][,; ]+\s*([5-9]|1[0-1])(?:[.,]([0-9]+))?\s*[°]?\s*[EeOo]`)
)

func loadELWISMailboxConfig() elwisMailboxConfig {
	host := strings.TrimSpace(os.Getenv("ELWIS_IMAP_HOST"))
	username := strings.TrimSpace(os.Getenv("ELWIS_IMAP_USER"))
	password := os.Getenv("ELWIS_IMAP_PASSWORD")
	port := envString("ELWIS_IMAP_PORT", "993")
	interval := 2 * time.Minute
	if raw := strings.TrimSpace(os.Getenv("ELWIS_POLL_INTERVAL")); raw != "" {
		if parsed, err := time.ParseDuration(raw); err == nil && parsed >= 30*time.Second {
			interval = parsed
		}
	}
	allowed := splitAndTrim(envString("ELWIS_ALLOWED_SENDERS", "elwis.de"), ",")
	return elwisMailboxConfig{
		enabled:        host != "" && username != "" && password != "",
		address:        net.JoinHostPort(host, port),
		username:       username,
		password:       password,
		mailbox:        envString("ELWIS_IMAP_MAILBOX", "INBOX"),
		region:         envString("ELWIS_REGION_PATH", defaultELWISRegion),
		allowedSenders: allowed,
		pollInterval:   interval,
	}
}

func (app *application) runELWISMailbox(ctx context.Context, config elwisMailboxConfig) {
	ticker := time.NewTicker(config.pollInterval)
	defer ticker.Stop()
	for {
		if err := app.pollELWISMailbox(ctx, config); err != nil {
			slog.Error("poll ELWIS mailbox", "error", err)
			app.updateELWISSyncState(context.Background(), err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (app *application) pollELWISMailbox(ctx context.Context, config elwisMailboxConfig) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	serverName, _, _ := net.SplitHostPort(config.address)
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: serverName}
	connection, err := client.DialTLS(config.address, tlsConfig)
	if err != nil {
		return fmt.Errorf("connect IMAP: %w", err)
	}
	defer connection.Logout()
	if err := connection.Login(config.username, config.password); err != nil {
		return fmt.Errorf("login IMAP: %w", err)
	}
	if _, err := connection.Select(config.mailbox, false); err != nil {
		return fmt.Errorf("select mailbox: %w", err)
	}

	criteria := imap.NewSearchCriteria()
	criteria.WithoutFlags = []string{imap.SeenFlag}
	uids, err := connection.UidSearch(criteria)
	if err != nil {
		return fmt.Errorf("search mailbox: %w", err)
	}
	sort.Slice(uids, func(i, j int) bool { return uids[i] < uids[j] })
	for _, uid := range uids {
		if err := ctx.Err(); err != nil {
			return err
		}
		processed, err := app.processELWISUID(ctx, connection, uid, config)
		if err != nil {
			slog.Error("process ELWIS message", "uid", uid, "error", err)
			continue
		}
		if processed {
			set := new(imap.SeqSet)
			set.AddNum(uid)
			if err := connection.UidStore(set, imap.FormatFlagsOp(imap.AddFlags, true), []interface{}{imap.SeenFlag}, nil); err != nil {
				return fmt.Errorf("mark ELWIS message seen: %w", err)
			}
		}
	}
	app.updateELWISSyncState(ctx, nil)
	return nil
}

func (app *application) processELWISUID(ctx context.Context, connection *client.Client, uid uint32, config elwisMailboxConfig) (bool, error) {
	set := new(imap.SeqSet)
	set.AddNum(uid)
	section := &imap.BodySectionName{}
	messages := make(chan *imap.Message, 1)
	done := make(chan error, 1)
	go func() {
		done <- connection.UidFetch(set, []imap.FetchItem{imap.FetchEnvelope, imap.FetchUid, section.FetchItem()}, messages)
	}()
	message, ok := <-messages
	if !ok || message == nil {
		return false, <-done
	}
	body := message.GetBody(section)
	if body == nil {
		return false, errors.New("IMAP message has no body")
	}
	raw, err := io.ReadAll(io.LimitReader(body, 4<<20))
	if err != nil {
		return false, err
	}
	if err := <-done; err != nil {
		return false, err
	}

	parsed, err := parseELWISMessage(raw, config)
	if err != nil {
		messageID := fmt.Sprintf("imap-uid-%d", uid)
		app.recordELWISIngestion(ctx, messageID, nil, "ignored", err.Error())
		return true, nil
	}
	if err := app.upsertMaritimeNotice(ctx, parsed.notice); err != nil {
		return false, err
	}
	return true, nil
}

func parseELWISMessage(raw []byte, config elwisMailboxConfig) (parsedELWISMail, error) {
	message, err := netmail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return parsedELWISMail{}, fmt.Errorf("read MIME message: %w", err)
	}
	subject := decodeMIMEHeader(message.Header.Get("Subject"))
	messageID := strings.Trim(strings.TrimSpace(message.Header.Get("Message-ID")), "<>")
	if messageID == "" {
		hash := sha256.Sum256(raw)
		messageID = "sha256-" + hex.EncodeToString(hash[:12])
	}
	sender := extractSender(message.Header.Get("From"))
	if !senderAllowed(sender, config.allowedSenders) {
		return parsedELWISMail{}, fmt.Errorf("sender %q is not allowed", sender)
	}
	body, err := decodeMIMEBody(textproto.MIMEHeader(message.Header), message.Body)
	if err != nil {
		return parsedELWISMail{}, fmt.Errorf("decode MIME body: %w", err)
	}
	body = normalizeNoticeBody(body)
	combined := subject + "\n" + body
	if !strings.Contains(strings.ToLower(combined), strings.ToLower(config.region)) &&
		!strings.Contains(strings.ToLower(combined), "ostfriesische inseln") {
		return parsedELWISMail{}, fmt.Errorf("message is outside configured region")
	}

	match := bfsNumberPattern.FindStringSubmatch(combined)
	if len(match) == 0 {
		return parsedELWISMail{}, errors.New("BfS number not found")
	}
	year := match[3]
	if len(year) == 2 {
		year = "20" + year
	}
	temporary := strings.TrimSpace(match[1]) != ""
	bfsNumber := "BfS "
	if temporary {
		bfsNumber += "(T) "
	}
	bfsNumber += match[2] + "/" + year

	publishedAt := parseMailDate(message.Header.Get("Date"))
	validFrom := parseMatchedDate(validFromPattern, body)
	validUntil := parseMatchedDate(validUntilPattern, body)
	state := noticeState(combined, validUntil)
	title := cleanNoticeTitle(subject, bfsNumber)
	if title == "" {
		title = bfsNumber
	}
	publisher := firstMatch(publisherPattern, body)
	if publisher == "" {
		publisher = "ELWIS / Wasserstraßen- und Schifffahrtsverwaltung des Bundes"
	}
	location := optionalString(firstMatch(locationPattern, body))
	sourceURL := firstELWISURL(combined)
	charts := splitReference(firstMatch(chartPattern, body))
	previous := splitReference(firstMatch(previousPattern, body))
	coordinates := parseCoordinates(body)
	parseStatus := "parsed"
	if location == nil || validFrom == nil {
		parseStatus = "partial"
	}

	identifierHash := sha256.Sum256([]byte(strings.ToLower(bfsNumber + "|" + config.region)))
	id := slugIdentifier(bfsNumber) + "-" + hex.EncodeToString(identifierHash[:5])
	contentHashBytes := sha256.Sum256([]byte(strings.Join([]string{title, body, state, pointerValue(location)}, "\n")))
	notice := maritimeNotice{
		ID: id, BFSNumber: bfsNumber, IsTemporary: temporary, Publisher: publisher,
		Title: title, RegionPath: config.region, Location: location, Body: body,
		PublishedAt: publishedAt, ValidFrom: validFrom, ValidUntil: validUntil,
		PublicationState: state, Revision: 1, SourceURL: sourceURL,
		ChartReferences: charts, Coordinates: coordinates, PreviousNotices: previous,
		ParseStatus: parseStatus, ContentHash: hex.EncodeToString(contentHashBytes[:]), MessageID: messageID,
	}
	return parsedELWISMail{notice: notice, sender: sender}, nil
}

func (app *application) upsertMaritimeNotice(ctx context.Context, notice maritimeNotice) error {
	tx, err := app.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var existingHash string
	var revision int
	err = tx.QueryRowContext(ctx, `
		SELECT content_hash, revision
		FROM maritime_notices
		WHERE id = $1
		FOR UPDATE
	`, notice.ID).Scan(&existingHash, &revision)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if err == nil && existingHash == notice.ContentHash {
		_, err = tx.ExecContext(ctx, `
			INSERT INTO elwis_ingestion_log (message_id, notice_id, status, detail)
			VALUES ($1, $2, 'duplicate', 'unchanged content')
			ON CONFLICT (message_id) DO NOTHING
		`, notice.MessageID, notice.ID)
		if err != nil {
			return err
		}
		return tx.Commit()
	}
	if err == nil {
		notice.Revision = revision + 1
	}

	charts, _ := json.Marshal(notice.ChartReferences)
	coordinates, _ := json.Marshal(notice.Coordinates)
	previous, _ := json.Marshal(notice.PreviousNotices)
	_, err = tx.ExecContext(ctx, `
		INSERT INTO maritime_notices (
			id, bfs_number, is_temporary, publisher, title, region_path, location, body,
			published_at, valid_from, valid_until, publication_state, revision, source_url,
			chart_references, coordinates, previous_notices, parse_status, content_hash, message_id,
			created_at, updated_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
			$15::jsonb, $16::jsonb, $17::jsonb, $18, $19, $20, now(), now()
		)
		ON CONFLICT (id) DO UPDATE SET
			bfs_number = EXCLUDED.bfs_number,
			is_temporary = EXCLUDED.is_temporary,
			publisher = EXCLUDED.publisher,
			title = EXCLUDED.title,
			region_path = EXCLUDED.region_path,
			location = EXCLUDED.location,
			body = EXCLUDED.body,
			published_at = EXCLUDED.published_at,
			valid_from = EXCLUDED.valid_from,
			valid_until = EXCLUDED.valid_until,
			publication_state = EXCLUDED.publication_state,
			revision = EXCLUDED.revision,
			source_url = EXCLUDED.source_url,
			chart_references = EXCLUDED.chart_references,
			coordinates = EXCLUDED.coordinates,
			previous_notices = EXCLUDED.previous_notices,
			parse_status = EXCLUDED.parse_status,
			content_hash = EXCLUDED.content_hash,
			message_id = EXCLUDED.message_id,
			updated_at = now()
	`, notice.ID, notice.BFSNumber, notice.IsTemporary, notice.Publisher, notice.Title,
		notice.RegionPath, notice.Location, notice.Body, notice.PublishedAt, notice.ValidFrom,
		notice.ValidUntil, notice.PublicationState, notice.Revision, notice.SourceURL,
		string(charts), string(coordinates), string(previous), notice.ParseStatus,
		notice.ContentHash, notice.MessageID)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO maritime_notice_revisions (
			notice_id, revision, body, publication_state, content_hash, message_id
		) VALUES ($1, $2, $3, $4, $5, $6)
	`, notice.ID, notice.Revision, notice.Body, notice.PublicationState, notice.ContentHash, notice.MessageID)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO elwis_ingestion_log (message_id, notice_id, status, detail)
		VALUES ($1, $2, 'processed', $3)
		ON CONFLICT (message_id) DO UPDATE SET status = EXCLUDED.status, detail = EXCLUDED.detail
	`, notice.MessageID, notice.ID, fmt.Sprintf("revision %d", notice.Revision))
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (app *application) recordELWISIngestion(ctx context.Context, messageID string, noticeID *string, status, detail string) {
	_, err := app.db.ExecContext(ctx, `
		INSERT INTO elwis_ingestion_log (message_id, notice_id, status, detail)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (message_id) DO UPDATE SET status = EXCLUDED.status, detail = EXCLUDED.detail
	`, messageID, noticeID, status, detail)
	if err != nil {
		slog.Error("record ELWIS ingestion", "error", err)
	}
}

func (app *application) updateELWISSyncState(ctx context.Context, syncErr error) {
	if syncErr == nil {
		_, _ = app.db.ExecContext(ctx, `
			UPDATE elwis_sync_state
			SET last_checked_at = now(), last_success_at = now(), last_error = NULL
			WHERE singleton = true
		`)
		return
	}
	_, _ = app.db.ExecContext(ctx, `
		UPDATE elwis_sync_state
		SET last_checked_at = now(), last_error = $1
		WHERE singleton = true
	`, syncErr.Error())
}

func (app *application) handleListMaritimeNotices(w http.ResponseWriter, r *http.Request) {
	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			limit = min(max(parsed, 1), 200)
		}
	}
	state := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("status")))
	condition := "TRUE"
	switch state {
	case "current":
		condition = "publication_state IN ('current', 'updated') AND (valid_until IS NULL OR valid_until >= now())"
	case "archive":
		condition = "publication_state IN ('revoked', 'expired') OR (valid_until IS NOT NULL AND valid_until < now())"
	}
	rows, err := app.db.QueryContext(r.Context(), fmt.Sprintf(`
		SELECT id, bfs_number, is_temporary, publisher, title, region_path, location,
		       published_at, valid_from, valid_until,
		       CASE WHEN valid_until IS NOT NULL AND valid_until < now() AND publication_state NOT IN ('revoked', 'expired')
		            THEN 'expired' ELSE publication_state END,
		       revision,
		       updated_at, source_url, parse_status
		FROM maritime_notices
		WHERE %s
		ORDER BY updated_at DESC
		LIMIT $1
	`, condition), limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Meldungen konnten nicht geladen werden")
		return
	}
	defer rows.Close()
	notices := make([]maritimeNotice, 0)
	for rows.Next() {
		notice, err := scanMaritimeNoticeSummary(rows)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "Meldungen konnten nicht gelesen werden")
			return
		}
		notices = append(notices, notice)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, "Meldungen konnten nicht gelesen werden")
		return
	}

	var lastSuccess sql.NullTime
	_ = app.db.QueryRowContext(r.Context(), `
		SELECT last_success_at FROM elwis_sync_state WHERE singleton = true
	`).Scan(&lastSuccess)
	var lastIngested *time.Time
	stale := true
	if lastSuccess.Valid {
		lastIngested = &lastSuccess.Time
		stale = time.Since(lastSuccess.Time) > 15*time.Minute
	}
	response := maritimeNoticeListResponse{Notices: notices, LastIngested: lastIngested, IsStale: stale}
	data, err := json.Marshal(response)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Meldungen konnten nicht serialisiert werden")
		return
	}
	noticeData, _ := json.Marshal(notices)
	hash := sha256.Sum256(append(noticeData, strconv.FormatBool(stale)...))
	etag := `"` + hex.EncodeToString(hash[:12]) + `"`
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (app *application) handleMaritimeNoticeDetail(w http.ResponseWriter, r *http.Request) {
	id, err := url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/maritime-notices/"))
	if err != nil || strings.TrimSpace(id) == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusBadRequest, "ungültige Meldungs-ID")
		return
	}
	row := app.db.QueryRowContext(r.Context(), `
		SELECT id, bfs_number, is_temporary, publisher, title, region_path, location, body,
		       published_at, valid_from, valid_until,
		       CASE WHEN valid_until IS NOT NULL AND valid_until < now() AND publication_state NOT IN ('revoked', 'expired')
		            THEN 'expired' ELSE publication_state END,
		       revision,
		       updated_at, source_url, chart_references, coordinates, previous_notices, parse_status
		FROM maritime_notices
		WHERE id = $1
	`, id)
	notice, err := scanMaritimeNoticeDetail(row)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "Meldung nicht gefunden")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "Meldung konnte nicht gelesen werden")
		return
	}
	writeJSON(w, http.StatusOK, notice)
}

type noticeScanner interface {
	Scan(...any) error
}

func scanMaritimeNoticeSummary(scanner noticeScanner) (maritimeNotice, error) {
	var notice maritimeNotice
	var location, sourceURL sql.NullString
	var publishedAt, validFrom, validUntil sql.NullTime
	err := scanner.Scan(
		&notice.ID, &notice.BFSNumber, &notice.IsTemporary, &notice.Publisher, &notice.Title,
		&notice.RegionPath, &location, &publishedAt, &validFrom, &validUntil,
		&notice.PublicationState, &notice.Revision, &notice.UpdatedAt, &sourceURL, &notice.ParseStatus,
	)
	if err != nil {
		return notice, err
	}
	notice.Location = nullStringPointer(location)
	notice.SourceURL = nullStringPointer(sourceURL)
	notice.PublishedAt = nullTimePointer(publishedAt)
	notice.ValidFrom = nullTimePointer(validFrom)
	notice.ValidUntil = nullTimePointer(validUntil)
	return notice, nil
}

func scanMaritimeNoticeDetail(scanner noticeScanner) (maritimeNotice, error) {
	var notice maritimeNotice
	var location, sourceURL sql.NullString
	var publishedAt, validFrom, validUntil sql.NullTime
	var charts, coordinates, previous []byte
	err := scanner.Scan(
		&notice.ID, &notice.BFSNumber, &notice.IsTemporary, &notice.Publisher, &notice.Title,
		&notice.RegionPath, &location, &notice.Body, &publishedAt, &validFrom, &validUntil,
		&notice.PublicationState, &notice.Revision, &notice.UpdatedAt, &sourceURL,
		&charts, &coordinates, &previous, &notice.ParseStatus,
	)
	if err != nil {
		return notice, err
	}
	notice.Location = nullStringPointer(location)
	notice.SourceURL = nullStringPointer(sourceURL)
	notice.PublishedAt = nullTimePointer(publishedAt)
	notice.ValidFrom = nullTimePointer(validFrom)
	notice.ValidUntil = nullTimePointer(validUntil)
	_ = json.Unmarshal(charts, &notice.ChartReferences)
	_ = json.Unmarshal(coordinates, &notice.Coordinates)
	_ = json.Unmarshal(previous, &notice.PreviousNotices)
	if notice.ChartReferences == nil {
		notice.ChartReferences = []string{}
	}
	if notice.Coordinates == nil {
		notice.Coordinates = []maritimeNoticeCoordinate{}
	}
	if notice.PreviousNotices == nil {
		notice.PreviousNotices = []string{}
	}
	return notice, nil
}

func decodeMIMEBody(header textproto.MIMEHeader, body io.Reader) (string, error) {
	mediaType, params, _ := mime.ParseMediaType(header.Get("Content-Type"))
	if strings.HasPrefix(mediaType, "multipart/") {
		boundary := params["boundary"]
		if boundary == "" {
			return "", errors.New("multipart boundary missing")
		}
		reader := multipart.NewReader(body, boundary)
		var plain, htmlBody string
		for {
			part, err := reader.NextPart()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				return "", err
			}
			content, err := decodeMIMEBody(part.Header, part)
			part.Close()
			if err != nil {
				continue
			}
			partType, _, _ := mime.ParseMediaType(part.Header.Get("Content-Type"))
			if partType == "text/plain" && plain == "" {
				plain = content
			}
			if partType == "text/html" && htmlBody == "" {
				htmlBody = content
			}
			if strings.HasPrefix(partType, "multipart/") && plain == "" {
				plain = content
			}
		}
		if plain != "" {
			return plain, nil
		}
		return htmlBody, nil
	}
	if mediaType != "" && mediaType != "text/plain" && mediaType != "text/html" {
		return "", nil
	}
	decoded := decodeTransferEncoding(header.Get("Content-Transfer-Encoding"), body)
	data, err := io.ReadAll(io.LimitReader(decoded, 4<<20))
	if err != nil {
		return "", err
	}
	text := decodeBodyCharset(data, params["charset"])
	if mediaType == "text/html" {
		text = htmlTagPattern.ReplaceAllString(text, " ")
		text = html.UnescapeString(text)
	}
	return text, nil
}

func decodeTransferEncoding(encoding string, body io.Reader) io.Reader {
	switch strings.ToLower(strings.TrimSpace(encoding)) {
	case "quoted-printable":
		return quotedprintable.NewReader(body)
	case "base64":
		return base64.NewDecoder(base64.StdEncoding, body)
	default:
		return body
	}
}

func decodeBodyCharset(data []byte, charset string) string {
	switch strings.ToLower(strings.TrimSpace(charset)) {
	case "iso-8859-1", "latin1", "latin-1":
		runes := make([]rune, len(data))
		for i, value := range data {
			runes[i] = rune(value)
		}
		return string(runes)
	default:
		return string(data)
	}
}

func decodeMIMEHeader(raw string) string {
	decoded, err := (&mime.WordDecoder{CharsetReader: func(charset string, input io.Reader) (io.Reader, error) {
		data, readErr := io.ReadAll(input)
		if readErr != nil {
			return nil, readErr
		}
		return strings.NewReader(decodeBodyCharset(data, charset)), nil
	}}).DecodeHeader(raw)
	if err != nil {
		return raw
	}
	return decoded
}

func extractSender(raw string) string {
	addresses, err := netmail.ParseAddressList(raw)
	if err != nil || len(addresses) == 0 {
		return strings.ToLower(strings.TrimSpace(raw))
	}
	return strings.ToLower(addresses[0].Address)
}

func senderAllowed(sender string, allowed []string) bool {
	if len(allowed) == 0 {
		return false
	}
	parts := strings.Split(sender, "@")
	domain := parts[len(parts)-1]
	for _, value := range allowed {
		value = strings.ToLower(strings.TrimSpace(value))
		if sender == value || domain == value || strings.HasSuffix(domain, "."+value) {
			return true
		}
	}
	return false
}

func normalizeNoticeBody(raw string) string {
	raw = strings.ReplaceAll(raw, "\r\n", "\n")
	raw = strings.ReplaceAll(raw, "\r", "\n")
	lines := strings.Split(raw, "\n")
	for i, line := range lines {
		lines[i] = strings.TrimSpace(spacePattern.ReplaceAllString(line, " "))
	}
	return strings.TrimSpace(multiBlankPattern.ReplaceAllString(strings.Join(lines, "\n"), "\n\n"))
}

func cleanNoticeTitle(subject, bfsNumber string) string {
	title := strings.TrimSpace(subject)
	for _, prefix := range []string{"[ELWIS-Abo]", "ELWIS-Abo:", "ELWIS:"} {
		title = strings.TrimSpace(strings.TrimPrefix(title, prefix))
	}
	title = strings.TrimSpace(strings.Replace(title, bfsNumber, "", 1))
	title = strings.Trim(title, "-: ")
	return title
}

func noticeState(content string, validUntil *time.Time) string {
	lower := strings.ToLower(content)
	if strings.Contains(lower, "aufgehoben") || strings.Contains(lower, "aufhebung") || strings.Contains(lower, "widerrufen") {
		return "revoked"
	}
	if validUntil != nil && validUntil.Before(time.Now()) {
		return "expired"
	}
	if strings.Contains(lower, "geändert") || strings.Contains(lower, "aenderung") || strings.Contains(lower, "berichtigung") {
		return "updated"
	}
	return "current"
}

func parseMailDate(raw string) *time.Time {
	if parsed, err := netmail.ParseDate(raw); err == nil {
		return &parsed
	}
	return nil
}

func parseMatchedDate(pattern *regexp.Regexp, body string) *time.Time {
	match := pattern.FindStringSubmatch(body)
	if len(match) < 2 {
		return nil
	}
	value := strings.TrimSpace(strings.TrimSuffix(match[1], "Uhr"))
	berlin, _ := time.LoadLocation("Europe/Berlin")
	for _, layout := range []string{"02.01.2006 15:04", "02.01.2006", "02.01.06 15:04", "02.01.06", time.RFC3339} {
		if parsed, err := time.ParseInLocation(layout, value, berlin); err == nil {
			return &parsed
		}
	}
	return nil
}

func firstMatch(pattern *regexp.Regexp, value string) string {
	match := pattern.FindStringSubmatch(value)
	if len(match) < 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

func firstELWISURL(value string) *string {
	for _, raw := range urlPattern.FindAllString(value, -1) {
		clean := strings.TrimRight(raw, ".,);]")
		parsed, err := url.Parse(clean)
		if err == nil && strings.Contains(strings.ToLower(parsed.Host), "elwis") {
			return &clean
		}
	}
	return nil
}

func parseCoordinates(body string) []maritimeNoticeCoordinate {
	result := []maritimeNoticeCoordinate{}
	for _, match := range coordinatePattern.FindAllStringSubmatch(body, -1) {
		latitude, latErr := strconv.ParseFloat(strings.ReplaceAll(match[1], ",", "."), 64)
		longitudeRaw := match[2]
		if len(match) > 3 && match[3] != "" {
			longitudeRaw += "." + match[3]
		}
		longitude, lonErr := strconv.ParseFloat(longitudeRaw, 64)
		if latErr == nil && lonErr == nil {
			result = append(result, maritimeNoticeCoordinate{Latitude: latitude, Longitude: longitude})
		}
	}
	return result
}

func splitReference(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return []string{}
	}
	parts := strings.FieldsFunc(raw, func(r rune) bool { return r == ',' || r == ';' })
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if clean := strings.TrimSpace(part); clean != "" {
			result = append(result, clean)
		}
	}
	return result
}

func splitAndTrim(raw, separator string) []string {
	parts := strings.Split(raw, separator)
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if clean := strings.TrimSpace(part); clean != "" {
			result = append(result, clean)
		}
	}
	return result
}

func slugIdentifier(raw string) string {
	raw = strings.ToLower(raw)
	var builder strings.Builder
	for _, value := range raw {
		if value >= 'a' && value <= 'z' || value >= '0' && value <= '9' {
			builder.WriteRune(value)
		} else if builder.Len() > 0 && !strings.HasSuffix(builder.String(), "-") {
			builder.WriteByte('-')
		}
	}
	return strings.Trim(builder.String(), "-")
}

func optionalString(value string) *string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	clean := strings.TrimSpace(value)
	return &clean
}
func pointerValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
func nullStringPointer(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	return &value.String
}
func nullTimePointer(value sql.NullTime) *time.Time {
	if !value.Valid {
		return nil
	}
	return &value.Time
}
