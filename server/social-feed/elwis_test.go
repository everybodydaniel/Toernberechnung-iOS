package main

import (
	"strings"
	"testing"
)

func TestParseELWISMessage(t *testing.T) {
	raw := strings.Join([]string{
		"From: ELWIS-Abo <abo@elwis.de>",
		"To: notice@example.test",
		"Date: Mon, 13 Jul 2026 18:30:00 +0200",
		"Message-ID: <bfs-123-2026@example.test>",
		"Subject: [ELWIS-Abo] BfS (T) 123/2026 - Sperrung im Fahrwasser",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"Deutschland.Nordsee.Ostfriesische Inseln",
		"Dienststelle: WSA Ems-Nordsee",
		"Ort: Norderney, Riffgat",
		"Gültig ab: 13.07.2026 20:00 Uhr",
		"Gültig bis: 15.07.2026 06:00 Uhr",
		"Karte: DE 90; ENC DE5NO1AA",
		"Die Fahrrinne ist vorübergehend gesperrt.",
		"https://www.elwis.de/DE/dynamisch/BfS/",
	}, "\r\n")

	parsed, err := parseELWISMessage([]byte(raw), testELWISConfig())
	if err != nil {
		t.Fatalf("parseELWISMessage() error = %v", err)
	}
	notice := parsed.notice
	if notice.BFSNumber != "BfS (T) 123/2026" {
		t.Fatalf("BFSNumber = %q", notice.BFSNumber)
	}
	if !notice.IsTemporary {
		t.Fatal("temporary notice was not detected")
	}
	if notice.Publisher != "WSA Ems-Nordsee" {
		t.Fatalf("Publisher = %q", notice.Publisher)
	}
	if notice.Location == nil || *notice.Location != "Norderney, Riffgat" {
		t.Fatalf("Location = %#v", notice.Location)
	}
	if notice.ValidFrom == nil || notice.ValidUntil == nil {
		t.Fatal("validity interval was not parsed")
	}
	if notice.SourceURL == nil || !strings.Contains(*notice.SourceURL, "elwis.de") {
		t.Fatalf("SourceURL = %#v", notice.SourceURL)
	}
	if notice.ParseStatus != "parsed" {
		t.Fatalf("ParseStatus = %q", notice.ParseStatus)
	}
}

func TestParseELWISMessageRejectsUnexpectedSender(t *testing.T) {
	raw := "From: sender@example.org\r\nSubject: BfS 1/2026\r\n\r\nDeutschland.Nordsee.Ostfriesische Inseln"
	if _, err := parseELWISMessage([]byte(raw), testELWISConfig()); err == nil {
		t.Fatal("unexpected sender was accepted")
	}
}

func TestNoticeStateDetectsRevocation(t *testing.T) {
	if got := noticeState("Diese BfS wird aufgehoben.", nil); got != "revoked" {
		t.Fatalf("noticeState() = %q", got)
	}
}

func testELWISConfig() elwisMailboxConfig {
	return elwisMailboxConfig{
		region:         defaultELWISRegion,
		allowedSenders: []string{"elwis.de"},
	}
}
