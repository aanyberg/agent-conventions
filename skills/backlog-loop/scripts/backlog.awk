# Parse or rewrite a BACKLOG.md. Works with POSIX awk (BWK awk on macOS, gawk, mawk).
#
#   awk -v mode=list  -f backlog.awk BACKLOG.md       -> id \t title \t open|blocked
#   awk -v mode=apply -v edits=FILE -f backlog.awk BACKLOG.md   -> rewritten file
#
# edits file: id \t done|blocked|review \t note
#
# Two item layouts are understood:
#   1. Table rows under a header row with "ID" and "Title" columns, with an
#      optional "Status" and "Notes" column. Rows under "## Archive" are skipped.
#   2. Checkbox lists: "- [ ] B-1: Title", "- [ ] **B-1** Title", "- [ ] [B-1] Title".
#      A checkbox without an id gets "item-<n>" from its position in the file.

function trim(s) {
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  return s
}

# Sets ITEM_ID and ITEM_TITLE from the text after a checkbox.
function split_checkbox(text,    rest) {
  ITEM_ID = ""
  ITEM_TITLE = text
  if (match(text, /^\*\*[^*]+\*\*[:. ]*/)) {
    ITEM_ID = substr(text, 3, index(substr(text, 3), "**") - 1)
    ITEM_TITLE = substr(text, RLENGTH + 1)
  } else if (match(text, /^\[[A-Za-z0-9_.-]+\][ \t]+/)) {
    ITEM_ID = substr(text, 2, index(text, "]") - 2)
    ITEM_TITLE = substr(text, RLENGTH + 1)
  } else if (match(text, /^#?[A-Za-z]*-?[0-9]+[:.)][ \t]+/)) {
    rest = substr(text, 1, RLENGTH)
    sub(/[:.)][ \t]+$/, "", rest)
    sub(/^#/, "", rest)
    ITEM_ID = rest
    ITEM_TITLE = substr(text, RLENGTH + 1)
  }
  ITEM_ID = trim(ITEM_ID)
  ITEM_TITLE = trim(ITEM_TITLE)
}

BEGIN {
  FS = "|"
  OFS = "|"
  if (mode == "apply") {
    while ((getline line < edits) > 0) {
      n = split(line, parts, "\t")
      if (n >= 2) {
        new_status[parts[1]] = parts[2]
        new_note[parts[1]] = parts[3]
      }
    }
    close(edits)
  }
}

/^##[ \t]/ {
  heading = tolower($0)
  skip = (heading ~ /archive/ || heading ~ /needs discussion/)
  in_table = 0
}

# Table rows.
/^[ \t]*\|/ {
  if (!in_table) {
    id_col = 0; title_col = 0; status_col = 0; notes_col = 0
    for (i = 2; i < NF; i++) {
      cell = tolower(trim($i))
      if (cell == "id") id_col = i
      else if (cell == "title") title_col = i
      else if (cell == "status") status_col = i
      else if (cell == "notes") notes_col = i
    }
    if (id_col && title_col) in_table = 1
    if (mode == "apply") print
    next
  }
  if ($0 ~ /^[ \t]*\|[ \t:|-]+\|[ \t]*$/) {
    if (mode == "apply") print
    next
  }
  id = trim($id_col)
  title = trim($title_col)
  status = status_col ? tolower(trim($status_col)) : ""
  if (mode == "list") {
    if (!skip && id != "" && status !~ /^(done|cancelled|canceled|merged|closed)$/) {
      printf "%s\t%s\t%s\n", id, title, (status == "blocked" || $0 ~ /BLOCKED:/) ? "blocked" : "open"
    }
    next
  }
  if (!skip && (id in new_status)) {
    if (new_status[id] != "review" && status_col) $status_col = " " new_status[id] " "
    note = ""
    if (new_status[id] == "blocked") note = "BLOCKED: " new_note[id]
    else if (new_status[id] == "review") note = "NEEDS-REVIEW: " new_note[id]
    else if (!status_col) note = "DONE"
    if (note != "") {
      target = notes_col ? notes_col : title_col
      $target = " " trim(trim($target) " " note) " "
    }
  }
  print
  next
}

# Checkbox items.
/^[ \t]*[-*][ \t]+\[[ xX]\][ \t]+/ {
  in_table = 0
  box_count++
  checked = ($0 ~ /^[ \t]*[-*][ \t]+\[[xX]\]/)
  text = $0
  sub(/^[ \t]*[-*][ \t]+\[[ xX]\][ \t]+/, "", text)
  blocked = (text ~ /BLOCKED:/)
  sub(/[ \t]*(—|-)?[ \t]*BLOCKED:.*$/, "", text)
  split_checkbox(text)
  if (ITEM_ID == "") ITEM_ID = "item-" box_count
  if (mode == "list") {
    if (!skip && !checked) printf "%s\t%s\t%s\n", ITEM_ID, ITEM_TITLE, blocked ? "blocked" : "open"
    next
  }
  if (!skip && !checked && (ITEM_ID in new_status)) {
    line = $0
    if (new_status[ITEM_ID] == "done") sub(/\[ \]/, "[x]", line)
    else if (new_status[ITEM_ID] == "blocked" && !blocked) line = line " — BLOCKED: " new_note[ITEM_ID]
    else if (new_status[ITEM_ID] == "review") line = line " — NEEDS-REVIEW: " new_note[ITEM_ID]
    print line
    next
  }
  print
  next
}

{
  in_table = 0
  if (mode == "apply") print
}
