-- Haushaltsprogramm, SQLite Schema, Fassung 10
-- Beträge immer in Cent als INTEGER, Einnahmen positiv, Ausgaben negativ.
-- Datumsangaben als ISO Text (YYYY-MM-DD), Monate als YYYY-MM.
-- Keine Konten. Der Kontostand ergibt sich aus Startsaldo plus Buchungen.

PRAGMA foreign_keys = ON;

-- Schlüssel Wert Speicher für alles, was der Nutzer einmal einstellt.
-- Bekannte Schlüssel: monatsbeginn ('1' oder 'gehalt'), startsaldo_cent,
-- startsaldo_datum, auto_bestaetigen ('0'/'1'), uebliches_anzeigen ('0'/'1'),
-- waehrung, schema_version
CREATE TABLE einstellungen (
    schluessel  TEXT PRIMARY KEY,
    wert        TEXT
);

INSERT INTO einstellungen (schluessel, wert) VALUES
    ('schema_version', '10'),
    ('monatsbeginn', '1'),
    ('auto_bestaetigen', '1'),
    ('uebliches_anzeigen', '1'),
    ('waehrung', 'EUR');

CREATE TABLE kategorien (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    gruppe      TEXT,                          -- z.B. 'Auto' für Tanken und Werkstatt
    icon        TEXT,
    farbe       TEXT,                          -- Hex, optional
    favorit     INTEGER NOT NULL DEFAULT 0,    -- festgepinnt in der Schnelleingabe
    sortierung  INTEGER NOT NULL DEFAULT 0,
    nutzungen   INTEGER NOT NULL DEFAULT 0,    -- Zähler für die Reihenfolge der Kacheln
    aktiv       INTEGER NOT NULL DEFAULT 1     -- beim ersten Start abgewählte Kategorien
);

-- Wiederkehrende Posten. Eine Änderung schließt die alte Regel (gilt_bis)
-- und legt eine neue an, die über ersetzt_regel_id auf die alte zeigt.
-- Nicht monatliche Posten (intervall_monate > 1) bekommen automatisch einen Topf.
CREATE TABLE regeln (
    id                INTEGER PRIMARY KEY,
    name              TEXT NOT NULL,
    betrag_cent       INTEGER NOT NULL,
    tag_im_monat      INTEGER NOT NULL CHECK (tag_im_monat BETWEEN 1 AND 31),
    intervall_monate  INTEGER NOT NULL DEFAULT 1 CHECK (intervall_monate IN (1, 3, 6, 12)),
    gilt_ab           TEXT NOT NULL,          -- erster Fälligkeitsmonat, YYYY-MM
    gilt_bis          TEXT,                   -- letzter Monat, NULL = offen
    gruppe            TEXT,                   -- übersteuert die Gruppe der Kategorie
    ersetzt_regel_id  INTEGER REFERENCES regeln(id),
    CHECK (gilt_bis IS NULL OR gilt_bis >= gilt_ab)
);

CREATE TABLE regel_kategorien (
    regel_id      INTEGER NOT NULL REFERENCES regeln(id) ON DELETE CASCADE,
    kategorie_id  INTEGER NOT NULL REFERENCES kategorien(id),
    PRIMARY KEY (regel_id, kategorie_id)
);

-- Töpfe sind verplantes Geld. Automatische Töpfe hängen an einer Regel,
-- eigene Töpfe haben Zielbetrag und Rate oder Zieldatum.
-- Der Füllstand wird nie gespeichert, sondern berechnet:
-- startstand + rate * verstrichene Monate seit start_monat + Einzahlungen - Entnahmen
CREATE TABLE toepfe (
    id               INTEGER PRIMARY KEY,
    name             TEXT NOT NULL,
    regel_id         INTEGER UNIQUE REFERENCES regeln(id) ON DELETE CASCADE,
    kategorie_id     INTEGER REFERENCES kategorien(id),  -- optional, nur zur Einordnung
    gruppe           TEXT,                    -- übersteuert die Gruppe der Kategorie
    ziel_cent        INTEGER,                 -- NULL bei reinem Puffer
    rate_cent        INTEGER NOT NULL,        -- monatliche Rücklage
    ziel_monat       TEXT,                    -- YYYY-MM, optional, Rate daraus errechnet
    startstand_cent  INTEGER NOT NULL DEFAULT 0,
    start_monat      TEXT NOT NULL,           -- ab wann die Rate läuft
    pausiert         INTEGER NOT NULL DEFAULT 0,
    aufgeloest_am    TEXT                     -- Datum, danach fließt der Rest ins freie Budget
);

-- Protokoll der Importe, damit ein Import als Ganzes rückgängig gemacht werden kann.
CREATE TABLE importe (
    id            INTEGER PRIMARY KEY,
    dateiname     TEXT NOT NULL,
    importiert_am TEXT NOT NULL DEFAULT (datetime('now')),
    anzahl        INTEGER NOT NULL DEFAULT 0
);

-- Jede tatsächliche oder geplante Geldbewegung.
-- art:    variabel | abschlag | nachzahlung | rueckzahlung | korrektur
-- status: geplant | gebucht
-- quelle: manuell | regel | import
CREATE TABLE buchungen (
    id            INTEGER PRIMARY KEY,
    datum         TEXT NOT NULL,              -- Buchungsdatum, frei überschreibbar
    betrag_cent   INTEGER NOT NULL,
    notiz         TEXT,
    gruppe        TEXT,                       -- übersteuert Posten und Kategorie
    -- Bewusste größere Ausgabe aus dem Konto, zählt nicht gegen das Monatsbudget
    ausserplanmaessig INTEGER NOT NULL DEFAULT 0,
    regel_id      INTEGER REFERENCES regeln(id),
    topf_id       INTEGER REFERENCES toepfe(id) ON DELETE SET NULL,
    art           TEXT NOT NULL DEFAULT 'variabel'
                  CHECK (art IN ('variabel', 'abschlag', 'nachzahlung', 'rueckzahlung', 'korrektur')),
    status        TEXT NOT NULL DEFAULT 'gebucht'
                  CHECK (status IN ('geplant', 'gebucht')),
    soll_monat    TEXT,                       -- YYYY-MM, nur bei generierten Abschlägen
    quelle        TEXT NOT NULL DEFAULT 'manuell'
                  CHECK (quelle IN ('manuell', 'regel', 'import')),
    import_id     INTEGER REFERENCES importe(id) ON DELETE SET NULL,
    import_hash   TEXT,                       -- sha256(datum|betrag|bank_zweck) der Bankbuchung
    bank_zweck    TEXT,                       -- Verwendungszweck aus dem Kontoauszug
    angelegt_am   TEXT NOT NULL DEFAULT (datetime('now')),
    CHECK (art IN ('variabel', 'korrektur') OR regel_id IS NOT NULL),
    CHECK (art <> 'abschlag' OR soll_monat IS NOT NULL)
);

-- Pro Regel und Monat höchstens ein Abschlag, damit die Fortschreibung idempotent ist.
CREATE UNIQUE INDEX ux_abschlag_monat
    ON buchungen(regel_id, soll_monat) WHERE art = 'abschlag';

-- Dieselbe Bankbuchung kann nie zweimal importiert werden.
CREATE UNIQUE INDEX ux_import_hash
    ON buchungen(import_hash) WHERE import_hash IS NOT NULL;

CREATE INDEX ix_buchungen_datum ON buchungen(datum);
CREATE INDEX ix_buchungen_topf  ON buchungen(topf_id);

CREATE TABLE buchung_kategorien (
    buchung_id    INTEGER NOT NULL REFERENCES buchungen(id) ON DELETE CASCADE,
    kategorie_id  INTEGER NOT NULL REFERENCES kategorien(id),
    PRIMARY KEY (buchung_id, kategorie_id)
);

-- Aufstockungen, also Geld, das außerhalb der Rate in einen Topf gelegt wird.
-- Es entsteht dabei keine Buchung, das Geld liegt ja schon auf dem Konto, es
-- ist nur nicht mehr frei verfügbar. Die Aufstockung steht als Ereignis mit
-- ihrem Monat da und nicht als umgeschriebener Startstand, damit der Füllstand
-- weiter gerechnet statt gespeichert wird und frühere Monate unberührt bleiben.
CREATE TABLE topf_einlagen (
    id           INTEGER PRIMARY KEY,
    topf_id      INTEGER NOT NULL REFERENCES toepfe(id) ON DELETE CASCADE,
    monat        TEXT NOT NULL,             -- YYYY-MM, ab dann wirkt sie
    betrag_cent  INTEGER NOT NULL,          -- immer positiv
    angelegt_am  TEXT NOT NULL DEFAULT (date('now'))
);
CREATE INDEX idx_topf_einlagen_topf ON topf_einlagen (topf_id, monat);

-- Notizregeln für automatische Kategorisierung, vor allem für den Import
CREATE TABLE notizregeln (
    id            INTEGER PRIMARY KEY,
    muster        TEXT NOT NULL,              -- Teilstring, Groß/Kleinschreibung egal
    kategorie_id  INTEGER NOT NULL REFERENCES kategorien(id) ON DELETE CASCADE
);

-- Zähler für die Kachelreihenfolge automatisch pflegen
CREATE TRIGGER trg_kategorie_nutzung
AFTER INSERT ON buchung_kategorien
BEGIN
    UPDATE kategorien SET nutzungen = nutzungen + 1 WHERE id = NEW.kategorie_id;
END;

-- Monatsübersicht, geplante und gebuchte Beträge getrennt
CREATE VIEW v_monat AS
SELECT substr(datum, 1, 7) AS monat,
       SUM(CASE WHEN betrag_cent > 0 AND status = 'gebucht' THEN betrag_cent ELSE 0 END) AS einnahmen_cent,
       SUM(CASE WHEN betrag_cent < 0 AND status = 'gebucht' THEN betrag_cent ELSE 0 END) AS ausgaben_cent,
       SUM(CASE WHEN regel_id IS NOT NULL THEN betrag_cent ELSE 0 END)                    AS fix_cent,
       SUM(CASE WHEN regel_id IS NULL AND betrag_cent < 0 THEN betrag_cent ELSE 0 END)   AS variabel_cent,
       SUM(CASE WHEN status = 'geplant' THEN betrag_cent ELSE 0 END)                      AS offen_cent,
       SUM(betrag_cent)                                                                    AS saldo_cent
FROM buchungen
GROUP BY monat;

-- Ausgaben je Kategorie und Monat, geplante Abschläge eingeschlossen
-- (Buchungen mit mehreren Kategorien zählen mehrfach)
-- Die wirksame Gruppe einer Buchung. Kategorie und Gruppe sind zwei getrennte
-- Merkmale, die Gruppe der Kategorie ist nur die Vorgabe. Der feste Posten
-- übersteuert sie, die einzelne Buchung übersteuert auch den Posten. Damit
-- liegen Haftpflicht und Kfz Versicherung beide in der Kategorie
-- Versicherungen, aber in den Gruppen Wohnkosten und Auto.
-- variabel_cent ist der Teil ohne festen Posten. Nur er lässt sich
-- sinnvoll anteilig zum verstrichenen Monat erwarten, eine Miete geht am
-- Ersten in einer Summe ab und wäre sonst jeden Monat ein Ausreißer.
-- Die wirksame Gruppe ist die der Buchung, sonst die des Postens, sonst die
-- des Topfs, aus dem bezahlt wurde, sonst die der Kategorie. NULL heißt nicht
-- gesetzt und erbt von der nächsten Stufe, ein leerer Text heißt bewusst
-- gelöscht, beendet die Vererbung und ergibt keine Gruppe, siehe Fassung 10.
-- Die Gruppe steht mit im GROUP BY, sonst würden Buchungen derselben Kategorie
-- mit verschiedenen Gruppen zu einer Zeile verschmelzen. Dort steht der
-- Ausdruck ausgeschrieben, der Alias gruppe wäre gegen die drei gleichnamigen
-- Spalten der verbundenen Tabellen mehrdeutig.
CREATE VIEW v_kategorie_monat AS
SELECT substr(b.datum, 1, 7)                    AS monat,
       k.name                                   AS kategorie,
       NULLIF(COALESCE(b.gruppe, r.gruppe, t.gruppe, k.gruppe), '') AS gruppe,
       SUM(b.betrag_cent)                       AS betrag_cent,
       SUM(CASE WHEN b.regel_id IS NULL THEN b.betrag_cent ELSE 0 END) AS variabel_cent,
       COUNT(*)                                 AS anzahl
FROM buchungen b
JOIN buchung_kategorien bk ON bk.buchung_id = b.id
JOIN kategorien k          ON k.id = bk.kategorie_id
LEFT JOIN regeln r         ON r.id = b.regel_id
LEFT JOIN toepfe t         ON t.id = b.topf_id
WHERE b.betrag_cent < 0
GROUP BY monat, kategorie, NULLIF(COALESCE(b.gruppe, r.gruppe, t.gruppe, k.gruppe), '');

-- Was hat ein fester Posten wirklich gekostet, Abschläge und Korrekturen zusammen
CREATE VIEW v_regel_jahr AS
SELECT substr(b.datum, 1, 4) AS jahr,
       r.name                 AS posten,
       SUM(CASE WHEN b.art = 'abschlag'     THEN b.betrag_cent ELSE 0 END) AS abschlaege_cent,
       SUM(CASE WHEN b.art = 'nachzahlung'  THEN b.betrag_cent ELSE 0 END) AS nachzahlungen_cent,
       SUM(CASE WHEN b.art = 'rueckzahlung' THEN b.betrag_cent ELSE 0 END) AS rueckzahlungen_cent,
       SUM(b.betrag_cent)                                                    AS gesamt_cent
FROM buchungen b
JOIN regeln r ON r.id = b.regel_id
WHERE b.status = 'gebucht'
GROUP BY jahr, posten;

-- Entnahmen und Einzahlungen je Topf, Rest des Füllstands rechnet die Anwendung
CREATE VIEW v_topf_bewegungen AS
SELECT t.id                 AS topf_id,
       t.name               AS topf,
       COALESCE(SUM(CASE WHEN b.betrag_cent < 0 THEN -b.betrag_cent ELSE 0 END), 0) AS entnahmen_cent,
       COALESCE(SUM(CASE WHEN b.betrag_cent > 0 THEN  b.betrag_cent ELSE 0 END), 0) AS einzahlungen_cent,
       COALESCE((SELECT SUM(e.betrag_cent) FROM topf_einlagen e WHERE e.topf_id = t.id), 0)
                            AS aufstockungen_cent
FROM toepfe t
LEFT JOIN buchungen b ON b.topf_id = t.id AND b.status = 'gebucht'
GROUP BY t.id;

-- Kategorien nach Zweck, nicht nach Ort
-- Vorbelegte Kategorien, Fassung 9. Die Kategorie sagt, was für eine Art
-- Ausgabe es ist, die Gruppe, zu welchem Lebensbereich sie gehört. Kein Wort
-- ist beides, siehe docs/Anleitung Haushaltsbuch.md, Kapitel 16. Wo die Art in ganz
-- verschiedene Lebensbereiche fällt, etwa Versicherungen, steht bewusst keine
-- Vorgabe, dort bekommt der Posten die Gruppe. Die frühere Gruppe Fixkosten
-- gibt es nicht mehr, Migration 9 bringt bestehende Datenbanken hierher.
INSERT INTO kategorien (name, gruppe, icon, sortierung) VALUES
    ('Lebensmittel',      'Essen und Trinken',   'basket',                   1),
    ('Haushalt',          'Wohnen',              'home',                     2),
    ('Gastronomie',       'Essen und Trinken',   'tools-kitchen-2',          3),
    ('Tanken',            'Auto',                'gas-station',              4),
    ('Werkstatt',         'Auto',                'tool',                     5),
    ('Fahrkarten',        'Unterwegs',           'train',                    6),
    ('Kleidung',          'Persönliches',        'shirt',                    7),
    ('Arzt und Apotheke', 'Gesundheit',          'heartbeat',                8),
    ('Kultur',            'Freizeit',            'masks-theater',            9),
    ('Medien',            'Freizeit',            'device-tv',               10),
    ('Hobbys',            'Freizeit',            'confetti',                11),
    ('Geschenke',         'Familie und Freunde', 'gift',                    12),
    ('Kurse',             'Weiterbildung',       'book',                    13),
    ('Reisen',            'Urlaub',              'plane',                   14),
    ('Steuern',           NULL,                  'ACCOUNT_BALANCE_OUTLINED', 15),
    ('Sonstiges',         NULL,                  'dots',                    16),
    ('Körperpflege',      'Persönliches',        'CONTENT_CUT',             17),
    ('Sport',             'Freizeit',            'FITNESS_CENTER',          18),
    ('Kinder',            'Familie und Freunde', 'CHILD_CARE',              19),
    ('Miete',             'Wohnen',              'building',                20),
    ('Energie',           'Wohnen',              'bolt',                    21),
    ('Versicherungen',    NULL,                  'shield',                  22),
    ('Kommunikation',     NULL,                  'wifi',                    23),
    ('Möbel und Geräte',  'Wohnen',              'CHAIR_OUTLINED',          24),
    ('Gebühren',          NULL,                  'RECEIPT_LONG_OUTLINED',   25),
    ('Kredite und Raten', 'Finanzen',            'CREDIT_CARD',             26),
    ('Spenden',           NULL,                  'VOLUNTEER_ACTIVISM',      27),
    ('Haustier',          'Familie und Freunde', 'PETS',                    28),
    ('Gehalt',            'Einnahmen',           'cash',                    30);
