Output venue-reader.mp4
Require nvim
Set Shell "bash"
Set Width 1280
Set Height 640
Set FontSize 21
Set FontFamily "Iosevka Nerd Font Mono"
Set Padding 16
Set Framerate 20
Set TypingSpeed 65ms
Set Theme "tokyonight"

Hide
Type@1ms 'work=$(mktemp -d); cp orders.fix "$work/orders.fix"; nvim -i NONE -u demo.lua "$work/orders.fix"'
Enter
Sleep 1.5s

# Keep a 1.5-second reading pause at the start of each numbered scene.
# The cue times in demo.srt start at those pauses. Update them when the tape timing changes.

# 1. Read the heartbeat as plain text.
Show
Sleep 1.5s
Sleep 1.5s

# 2. Enable FIX annotations.
Sleep 1.5s
Type "1G"
Sleep 1s
Type ":set ft=fix"
Enter
Sleep 4s

# 3. Find Side in the picker and jump to the tag.
Sleep 1.5s
Type "2G"
Sleep 1s
Type ":VenueReader symbols"
Enter
Sleep 2s
Type "Side"
Sleep 1s
Down
Sleep 1s
Enter
Sleep 600ms

# 4. Open hover for Side(54) to see that 1 means Buy.
Sleep 1.5s
Type "K"
Sleep 2s

# 5. Navigate between the bid price and size.
Sleep 1.5s
Type "3G"
Sleep 1s
Type "/270=123[.]40"
Enter
Type "]]"
Sleep 800ms
Type "[["
Sleep 800ms
Type "]]"
Sleep 800ms

# 6. Yank the decoded bid size and paste it into a split.
Sleep 2.5s
Sleep 1s
Type ":VenueReader yank"
Enter
Sleep 500ms
Type ":belowright new"
Enter
Type "p"
Sleep 2s
Type ":q"
Enter

# 7. Change the bid size to trigger integrity diagnostics.
Sleep 1.5s
Type "3G"
Sleep 1s
Type "/271=200"
Enter
Type "f=ea0"
Escape
Sleep 1.5s

# 8. Repair the updated message.
Sleep 1.5s
Sleep 1s
Type "gra"
Sleep 2s
Type "BodyLength"
Sleep 500ms
Enter
Sleep 2s

# 9. Inspect tag 789 in a FIX 4.4 Logon.
Sleep 1.5s
Type "4G0"
Type "/789=5"
Enter
Type "K"
Sleep 2.5s

# 10. Switch the session dictionary from FIX 4.4 to FIX 4.3.
Sleep 1.5s
Type ":VenueReader dictionary"
Enter
Sleep 1.5s
Type "FIX.4.3"
Sleep 1s
Enter
Sleep 1.2s

# 11. Change the Logon to FIX 4.3 and inspect tag 789.
Sleep 1.5s
Type "4G0"
Sleep 1s
Type "f4;r3"
Sleep 1s
Type "$hr6"
Sleep 1s
Type "4G0"
Type "/789=5"
Enter
Ctrl+w
Type "d"
Sleep 3s


# 12. Disable message summaries and the dictionary version warning with a modeline.
Sleep 1.5s
# TODO: remove after 'debounce-modeline-updates'. Print as regular text, don't paste it.
Type ":0put ='# fix: diagnostics.rules.dictionaryVersion=false messageSummary.enabled=false'"
Enter
Sleep 1.5s
Type "G0"
Type "/789=5"
Enter
Ctrl+w
Type "d"
Sleep 3s
Hide
Type ":qa!"
Enter
