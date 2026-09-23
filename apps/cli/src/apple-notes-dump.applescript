-- Exports every non-password-protected note from Notes.app into a
-- delimited file. Called by apps/cli/src/cmd-apple-notes.ts.
--
-- Output (temp file path returned via stdout):
--   <folder_path><title><created_iso><updated_iso><pinned><body_html>
-- Timestamps are local time; the TS side normalizes to UTC using the
-- machine's timezone offset. Control chars  (Unit Separator) and
--  (Record Separator) are chosen because they're extraordinarily
-- unlikely to appear in real note content.
--
-- Usage from shell:
--   osascript apple-notes-dump.applescript <limit> <include_locked>
--     limit:          0 = no cap; positive int caps total notes emitted
--     include_locked: "true" to attempt locked notes (will error on any)

on run argv
    set limitN to 0
    set includeLocked to false
    if (count of argv) ≥ 1 then set limitN to (item 1 of argv as integer)
    if (count of argv) ≥ 2 then set includeLocked to ((item 2 of argv) is "true")

    set FS to character id 31
    set RS to character id 30

    set noteCount to 0
    set outPath to "/tmp/apple-notes-cloudflare-mcp-dump-" & (do shell script "date +%s")
    set fh to open for access (POSIX file outPath) with write permission
    set eof of fh to 0

    tell application "Notes"
        set allAccounts to accounts
    end tell

    repeat with theAccount in allAccounts
        tell application "Notes"
            set accountFolders to folders of theAccount
        end tell
        repeat with theFolder in accountFolders
            set noteCount to my walkFolder(theFolder, "", fh, noteCount, limitN, includeLocked, FS, RS)
            if limitN > 0 and noteCount ≥ limitN then exit repeat
        end repeat
    end repeat

    close access fh
    return outPath
end run

on walkFolder(theFolder, prefix, fh, noteCount, limitN, includeLocked, FS, RS)
    tell application "Notes"
        set folderName to name of theFolder as text
        set theNotes to notes of theFolder
        set subFolders to folders of theFolder
    end tell
    if prefix is "" then
        set folderPath to folderName
    else
        set folderPath to prefix & "/" & folderName
    end if

    repeat with theNote in theNotes
        if limitN > 0 and noteCount ≥ limitN then return noteCount
        set noteCount to my emitNote(theNote, folderPath, fh, noteCount, includeLocked, FS, RS)
    end repeat

    repeat with subFolder in subFolders
        if limitN > 0 and noteCount ≥ limitN then return noteCount
        set noteCount to my walkFolder(subFolder, folderPath, fh, noteCount, limitN, includeLocked, FS, RS)
    end repeat
    return noteCount
end walkFolder

on emitNote(theNote, folderPath, fh, noteCount, includeLocked, FS, RS)
    tell application "Notes"
        try
            set isLocked to password protected of theNote as boolean
        on error
            set isLocked to false
        end try
        if isLocked and not includeLocked then return noteCount

        try
            set noteName to name of theNote as text
            set noteBody to body of theNote as text
            try
                set notePinned to pinned of theNote as boolean
            on error
                set notePinned to false
            end try
            set createdDate to creation date of theNote
            set updatedDate to modification date of theNote
        on error errMsg
            -- skip unreadable notes (usually locked or corrupt)
            return noteCount
        end try
    end tell

    set createdIso to my iso8601(createdDate)
    set updatedIso to my iso8601(updatedDate)
    set pinnedText to "false"
    if notePinned then set pinnedText to "true"

    set rec to folderPath & FS & noteName & FS & createdIso & FS & updatedIso & FS & pinnedText & FS & noteBody & RS
    write rec to fh as «class utf8»
    return noteCount + 1
end emitNote

on iso8601(d)
    -- Local-time ISO-ish string (no tz suffix). TS reinterprets with the
    -- machine's timezone to produce a true UTC timestamp.
    set y to year of d as integer
    set m to month of d as integer
    set dd to day of d as integer
    set h to hours of d as integer
    set mn to minutes of d as integer
    set s to seconds of d as integer
    return (y as text) & "-" & my pad2(m) & "-" & my pad2(dd) & "T" & my pad2(h) & ":" & my pad2(mn) & ":" & my pad2(s)
end iso8601

on pad2(n)
    set i to n as integer
    if i < 10 then return "0" & (i as text)
    return i as text
end pad2
