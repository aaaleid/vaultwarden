-- Notes are no longer length-limited by Vaultwarden, so the column must be able
-- to hold values larger than TEXT's 64 KiB.
ALTER TABLE ciphers MODIFY notes LONGTEXT;
