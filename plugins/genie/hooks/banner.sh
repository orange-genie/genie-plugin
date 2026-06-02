#!/usr/bin/env bash
# 🍊 Orange Genie — startup banner. Prints the brand splash when a Claude Code
# session opens with the plugin installed. True-color: orange gradient wordmark
# (#ffc061→#be4400) + blue accent (#6b9fff) + dim grey. Box inner width = 46 cols.
e=$'\033'
R="${e}[0m"; B="${e}[1m"
D="${e}[38;5;245m"            # dim grey
BL="${e}[38;2;107;159;255m"   # blue accent  #6b9fff
OR="${e}[38;2;247;107;0m"     # base orange  #f76b00
BAR='──────────────────────────────────────────────'   # 46

# Build the gradient wordmark "ORANGE GENIE" (12 visible cols).
chars=(O R A N G E ' ' G E N I E)
grad=(255:192:97 255:179:71 255:161:46 251:139:30 249:125:18 247:107:0 0:0:0 247:107:0 236:99:0 224:89:0 212:82:0 190:68:0)
WORD=""
for i in "${!chars[@]}"; do
  c="${chars[$i]}"
  if [ "$c" = ' ' ]; then WORD+=' '; continue; fi
  IFS=: read -r r g b <<< "${grad[$i]}"
  WORD+="${e}[1;38;2;${r};${g};${b}m${c}"
done
WORD+="$R"

printf '\n'
printf '  %s╭%s╮%s\n' "$OR" "$BAR" "$R"
printf '  %s│%s                                              %s│%s\n' "$OR" "$R" "$OR" "$R"
printf '  %s│%s   🍊  %s                           %s│%s\n' "$OR" "$R" "$WORD" "$OR" "$R"
printf '  %s│%s   %sthe lamp is lit · wildflower chain online%s  %s│%s\n' "$OR" "$R" "$D" "$R" "$OR" "$R"
printf '  %s│%s                                              %s│%s\n' "$OR" "$R" "$OR" "$R"
printf '  %s│%s   %s▸%s %s%s/genie%s %swake%s    %s▸%s %s%s/lamp%s %saway%s              %s│%s\n' \
  "$OR" "$R" "$OR" "$R" "$B" "$OR" "$R" "$D" "$R" "$BL" "$R" "$B" "$BL" "$R" "$D" "$R" "$OR" "$R"
printf '  %s│%s                                              %s│%s\n' "$OR" "$R" "$OR" "$R"
printf '  %s╰%s╯%s\n' "$OR" "$BAR" "$R"
printf '\n'
