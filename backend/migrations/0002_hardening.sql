-- D01i Tweakz - migracja 0002: twardnienie (audyt)
BEGIN;

-- B3: limit urzadzen to regula produktu (maks. 2). Najpierw niedestrukcyjnie
-- obcinamy ewentualne istniejace wartosci > 2, potem dokładamy CHECK.
UPDATE licenses SET max_devices = 2 WHERE max_devices > 2;
ALTER TABLE licenses DROP CONSTRAINT IF EXISTS licenses_max_devices_check;
ALTER TABLE licenses ADD CONSTRAINT licenses_max_devices_check CHECK (max_devices >= 1 AND max_devices <= 2);

-- B2: hwid_hash może byc NULL po resecie urzadzen przez admina - wtedy ponowna
-- aktywacja wiaze nowy HWID (kontrolowana procedura), zamiast cichej podmiany.
ALTER TABLE devices ALTER COLUMN hwid_hash DROP NOT NULL;

COMMIT;
