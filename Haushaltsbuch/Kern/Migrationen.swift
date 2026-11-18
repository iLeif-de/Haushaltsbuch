import Foundation

/// Die Migrationen von Fassung 3 bis 10, unverändert aus haushalt/db.py
/// übernommen am 26. September 2026. Jeder Eintrag bringt eine bestehende
/// Datenbank von seiner Nummer minus eins auf seine Nummer. Begründet sind sie
/// in haushalt/db.py und docs/technik.md, dort stehen die Kommentare zu jeder.
///
/// Eine neue Migration kommt ab jetzt nur noch hier dazu, mit der angehobenen
/// Zahl in `Datenbank.schemaFassung`, im Kopf von schema.sql und in dessen
/// INSERT auf schema_version.
enum Migrationen {
    static let alle: [Int: String] = [
        3: #"""
        ALTER TABLE toepfe ADD COLUMN kategorie_id INTEGER REFERENCES kategorien(id);
        """#,
        4: #"""
        INSERT OR IGNORE INTO kategorien (name, gruppe, icon, sortierung) VALUES ('Steuern', NULL, 'ACCOUNT_BALANCE_OUTLINED', 15);
        """#,
        5: #"""
        ALTER TABLE regeln    ADD COLUMN gruppe TEXT;
        ALTER TABLE toepfe    ADD COLUMN gruppe TEXT;
        ALTER TABLE buchungen ADD COLUMN gruppe TEXT;
        DROP VIEW IF EXISTS v_kategorie_monat;
        CREATE VIEW v_kategorie_monat AS
        SELECT substr(b.datum, 1, 7)                  AS monat,
               k.name                                 AS kategorie,
               COALESCE(b.gruppe, r.gruppe, k.gruppe) AS gruppe,
               SUM(b.betrag_cent)                     AS betrag_cent,
               COUNT(*)                               AS anzahl
        FROM buchungen b
        JOIN buchung_kategorien bk ON bk.buchung_id = b.id
        JOIN kategorien k          ON k.id = bk.kategorie_id
        LEFT JOIN regeln r         ON r.id = b.regel_id
        WHERE b.betrag_cent < 0
        GROUP BY monat, kategorie, COALESCE(b.gruppe, r.gruppe, k.gruppe);
        """#,
        6: #"""
        ALTER TABLE buchungen ADD COLUMN ausserplanmaessig INTEGER NOT NULL DEFAULT 0;
        """#,
        7: #"""
        DROP VIEW IF EXISTS v_kategorie_monat;
        CREATE VIEW v_kategorie_monat AS
        SELECT substr(b.datum, 1, 7)                    AS monat,
               k.name                                   AS kategorie,
               COALESCE(b.gruppe, r.gruppe, k.gruppe)   AS gruppe,
               SUM(b.betrag_cent)                       AS betrag_cent,
               SUM(CASE WHEN b.regel_id IS NULL THEN b.betrag_cent ELSE 0 END) AS variabel_cent,
               COUNT(*)                                 AS anzahl
        FROM buchungen b
        JOIN buchung_kategorien bk ON bk.buchung_id = b.id
        JOIN kategorien k          ON k.id = bk.kategorie_id
        LEFT JOIN regeln r         ON r.id = b.regel_id
        WHERE b.betrag_cent < 0
        GROUP BY monat, kategorie, COALESCE(b.gruppe, r.gruppe, k.gruppe);
        """#,
        8: #"""
        CREATE TABLE topf_einlagen (
            id           INTEGER PRIMARY KEY,
            topf_id      INTEGER NOT NULL REFERENCES toepfe(id) ON DELETE CASCADE,
            monat        TEXT NOT NULL,
            betrag_cent  INTEGER NOT NULL,
            angelegt_am  TEXT NOT NULL DEFAULT (date('now'))
        );
        CREATE INDEX idx_topf_einlagen_topf ON topf_einlagen (topf_id, monat);
        DROP VIEW IF EXISTS v_topf_bewegungen;
        CREATE VIEW v_topf_bewegungen AS
        SELECT t.id   AS topf_id,
               t.name AS topf,
               COALESCE(SUM(CASE WHEN b.betrag_cent < 0 THEN -b.betrag_cent ELSE 0 END), 0)
                      AS entnahmen_cent,
               COALESCE(SUM(CASE WHEN b.betrag_cent > 0 THEN  b.betrag_cent ELSE 0 END), 0)
                      AS einzahlungen_cent,
               COALESCE((SELECT SUM(e.betrag_cent) FROM topf_einlagen e WHERE e.topf_id = t.id), 0)
                      AS aufstockungen_cent
        FROM toepfe t
        LEFT JOIN buchungen b ON b.topf_id = t.id AND b.status = 'gebucht'
        GROUP BY t.id;
        """#,
        9: #"""
        -- Erst die Vorgaben der fünf alten Kategorien, noch unter ihrem alten
        -- Namen. Erst danach umbenennen, sonst träfe die Vorgabe auch eine
        -- Kategorie, die der Nutzer selbst schon unter dem neuen Namen hat.
        -- Umgestellt wird nur, wo noch der Wert aus Fassung 8 steht, das war
        -- Fixkosten bei Wohnen, Energie, Versicherungen und Kommunikation und
        -- keine Gruppe bei den übrigen.
        UPDATE kategorien SET gruppe='Wohnen'        WHERE name='Wohnen'     AND gruppe='Fixkosten';
        UPDATE kategorien SET gruppe='Unterwegs'     WHERE name='Mobilität'  AND gruppe IS NULL;
        UPDATE kategorien SET gruppe='Gesundheit'    WHERE name='Gesundheit' AND gruppe IS NULL;
        UPDATE kategorien SET gruppe='Freizeit'      WHERE name='Freizeit'   AND gruppe IS NULL;
        UPDATE kategorien SET gruppe='Weiterbildung' WHERE name='Bildung'    AND gruppe IS NULL;

        -- Umbenennen, nur wenn der alte Name noch da ist und der neue noch
        -- frei. Die Buchungen hängen an der id und folgen sofort.
        UPDATE kategorien SET name='Miete'
            WHERE name='Wohnen' AND NOT EXISTS (SELECT 1 FROM kategorien WHERE name='Miete');
        UPDATE kategorien SET name='Fahrkarten'
            WHERE name='Mobilität' AND NOT EXISTS (SELECT 1 FROM kategorien WHERE name='Fahrkarten');
        UPDATE kategorien SET name='Arzt und Apotheke'
            WHERE name='Gesundheit' AND NOT EXISTS (SELECT 1 FROM kategorien WHERE name='Arzt und Apotheke');
        UPDATE kategorien SET name='Hobbys'
            WHERE name='Freizeit' AND NOT EXISTS (SELECT 1 FROM kategorien WHERE name='Hobbys');
        UPDATE kategorien SET name='Kurse'
            WHERE name='Bildung' AND NOT EXISTS (SELECT 1 FROM kategorien WHERE name='Kurse');

        -- Die Vorgaben der übrigen, deren Namen bleiben
        UPDATE kategorien SET gruppe='Wohnen' WHERE name='Energie' AND gruppe='Fixkosten';
        UPDATE kategorien SET gruppe=NULL     WHERE name IN ('Versicherungen', 'Kommunikation') AND gruppe='Fixkosten';
        UPDATE kategorien SET gruppe='Essen und Trinken'   WHERE name IN ('Lebensmittel', 'Gastronomie') AND gruppe IS NULL;
        UPDATE kategorien SET gruppe='Wohnen'              WHERE name='Haushalt' AND gruppe IS NULL;
        UPDATE kategorien SET gruppe='Persönliches'        WHERE name='Kleidung' AND gruppe IS NULL;
        UPDATE kategorien SET gruppe='Freizeit'            WHERE name IN ('Kultur', 'Medien') AND gruppe IS NULL;
        UPDATE kategorien SET gruppe='Familie und Freunde' WHERE name='Geschenke' AND gruppe IS NULL;
        UPDATE kategorien SET gruppe='Urlaub'              WHERE name='Reisen' AND gruppe IS NULL;

        -- Die neuen Kategorien. Eine umbenannte, die der Nutzer gelöscht
        -- hatte, kommt dagegen nicht zurück, das war seine Entscheidung.
        INSERT OR IGNORE INTO kategorien (name, gruppe, icon, sortierung) VALUES
            ('Körperpflege',      'Persönliches',        'CONTENT_CUT',           17),
            ('Sport',             'Freizeit',            'FITNESS_CENTER',        18),
            ('Kinder',            'Familie und Freunde', 'CHILD_CARE',            19),
            ('Möbel und Geräte',  'Wohnen',              'CHAIR_OUTLINED',        24),
            ('Gebühren',          NULL,                  'RECEIPT_LONG_OUTLINED', 25),
            ('Kredite und Raten', 'Finanzen',            'CREDIT_CARD',           26),
            ('Spenden',           NULL,                  'VOLUNTEER_ACTIVISM',    27),
            ('Haustier',          'Familie und Freunde', 'PETS',                  28);
        """#,
        10: #"""
        DROP VIEW IF EXISTS v_kategorie_monat;
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
        """#,
    ]
}
