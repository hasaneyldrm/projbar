# ~/.tmux-proj.zsh — projeleri renkli, isimli tmux session'lari olarak yonet
# Kullanim:
#   proj <ad>     -> projeyi ac/gec (yoksa olustur: shell/server/claude pencereleri)
#   projw <ad>    -> projeyi YENI bir Terminal penceresinde ac (ayri renkli pencere)
#   projs         -> acik proje session'larini listele
#   projk <ad>    -> projeyi kapat (session'u oldur)
# Renk: proje adina gore sabit. Pin'lemek istersen asagidaki PROJ_COLORS'a ekle.

PROJ_BASE="${PROJ_BASE:-$HOME/Documents/projects}"

# Sabit renk atamalari (256-color kodu). Istedigin projeyi buraya sabitle.
typeset -gA PROJ_COLORS
PROJ_COLORS=(
  # ornek: proje-dizin-adi  256-renk-kodu
  my-app       124   # kirmizi
  my-api       25    # mavi
  my-website   22    # yesil
)

# Kisa ad -> tam proje dizin adi. Istedigin kisayolu buraya ekle.
typeset -gA PROJ_ALIAS
PROJ_ALIAS=(
  # ornek: kisa-ad  tam-dizin-adi
  app   my-app
  api   my-api
  web   my-website
)

# Ad -> renk (map'te yoksa isimden deterministik uret; od/awk spawn'i
# her cd'de tekrarlamamak icin sonuc cache'lenir)
typeset -gA __PROJ_COLOR_CACHE
__proj_color() {
  local name="$1"
  if [[ -n "${__PROJ_COLOR_CACHE[$name]}" ]]; then
    print -r -- "${__PROJ_COLOR_CACHE[$name]}"; return
  fi
  if [[ -n "${PROJ_COLORS[$name]}" ]]; then
    __PROJ_COLOR_CACHE[$name]="${PROJ_COLORS[$name]}"
    print -r -- "${PROJ_COLORS[$name]}"; return
  fi
  local -a palette
  palette=(124 25 22 54 130 23 90 94 61 125 100 53 166 30 133 65)
  local sum
  sum=$(printf '%s' "$name" | od -An -tu1 | awk '{for(i=1;i<=NF;i++)s+=$i} END{print s+0}')
  __PROJ_COLOR_CACHE[$name]="${palette[$(( sum % ${#palette} + 1 ))]}"
  print -r -- "${__PROJ_COLOR_CACHE[$name]}"
}

# Kisa ad / alias / substring -> tam proje dizin adi (bulamazsa hata basip 1 doner)
__proj_resolve() {
  local raw="$1"
  [[ -d "$PROJ_BASE/$raw" ]] && { print -r -- "$raw"; return 0; }        # tam dizin adi
  [[ -n "${PROJ_ALIAS[$raw]}" ]] && { print -r -- "${PROJ_ALIAS[$raw]}"; return 0; }  # alias
  local -a dirs matches; local d low="${(L)raw}"                          # substring (buyuk/kucuk fark etmez)
  dirs=( ${PROJ_BASE}/*(/N:t) )
  for d in $dirs; do [[ "${(L)d}" == *"$low"* ]] && matches+=("$d"); done
  (( ${#matches} == 1 )) && { print -r -- "${matches[1]}"; return 0; }
  (( ${#matches} > 1 )) && { print -u2 -- "Belirsiz '$raw' -> ${matches[*]}"; return 1; }
  print -u2 -- "Proje yok: $raw"; return 1
}

# session'a renkli status bar + baslik uygula
# not: set-option, tmux 3.7'de "=isim" tam-eslesme onekini tanimiyor -> oneksiz isim
__proj_style() {
  local s="$1" c="$2"
  tmux set-option -t "$s" status-style "bg=colour${c},fg=colour231"
  tmux set-option -t "$s" status-left "#[bold] ● #S #[nobold]"
  tmux set-option -t "$s" window-status-current-style "reverse,bold"
}

proj() {
  command -v tmux >/dev/null || { echo "tmux yok"; return 1; }
  local name="$1"
  if [[ -z "$name" ]]; then projs; return; fi
  name=$(__proj_resolve "$name") || return 1
  local dir="$PROJ_BASE/$name"
  local color; color=$(__proj_color "$name")

  if ! tmux has-session -t "=$name" 2>/dev/null; then
    tmux new-session -d -s "$name" -c "$dir" -n shell
    tmux new-window  -t "=$name" -c "$dir" -n server
    tmux new-window  -t "=$name" -c "$dir" -n claude
    tmux select-window -t "=${name}:shell"
    __proj_style "$name" "$color"
  fi

  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "=$name"
  else
    tmux attach-session -t "=$name"
  fi
}

# p <ad> -> projeyi DOGRUDAN claude ile ac.
#   - session zaten acikssa (icinde calisan claude'a) attach eder, yenisini kurmaz.
#   - yoksa session'i kurar + claude penceresinde 'claude'u otomatik baslatir.
#   Kisa ad olur: p query, p q, p fit ...
p() {
  command -v tmux >/dev/null || { echo "tmux yok"; return 1; }
  local raw="$1"
  [[ -z "$raw" ]] && { echo "kullanim: p <proje>   (kisa ad olur: p query, p q, p fit)"; return 1; }
  local name; name=$(__proj_resolve "$raw") || return 1
  local dir="$PROJ_BASE/$name"

  if tmux has-session -t "=$name" 2>/dev/null; then
    # ZATEN ACIK -> calisan session'a don, claude penceresini sec
    tmux select-window -t "=${name}:claude" 2>/dev/null
  else
    # YENI -> kur ve claude'u otomatik baslat
    local color; color=$(__proj_color "$name")
    tmux new-session -d -s "$name" -c "$dir" -n shell
    tmux new-window  -t "=$name" -c "$dir" -n server
    tmux new-window  -t "=$name" -c "$dir" -n claude
    tmux send-keys   -t "=${name}:claude" 'claude' C-m
    tmux select-window -t "=${name}:claude"
    __proj_style "$name" "$color"
  fi

  if [[ -n "$TMUX" ]]; then tmux switch-client -t "=$name"
  else tmux attach-session -t "=$name"; fi
}

# projeyi yeni bir Terminal penceresinde ac (ayri, renkli pencere)
projw() {
  local raw="$1"
  [[ -z "$raw" ]] && { echo "kullanim: projw <proje>"; return 1; }
  local name; name=$(__proj_resolve "$raw") || return 1
  osascript -e "tell application \"Terminal\" to do script \"proj ${name}\"" >/dev/null
  osascript -e 'tell application "Terminal" to activate' >/dev/null
}

# acik proje session'larini listele
projs() {
  command -v tmux >/dev/null || { echo "tmux yok"; return 1; }
  local out
  out=$(tmux ls 2>/dev/null) || { echo "Aktif session yok. 'proj <ad>' ile baslat."; return; }
  print -r -- "$out"
}

# projeyi kapat
projk() {
  local raw="$1"
  [[ -z "$raw" ]] && { echo "kullanim: projk <proje>"; return 1; }
  local name; name=$(__proj_resolve "$raw") || return 1
  tmux kill-session -t "=$name" 2>/dev/null && echo "kapatildi: $name" || echo "session yok: $name"
}

# tab-completion: projects klasorundeki dizinler
_proj() {
  local -a names
  names=( ${PROJ_BASE}/*(/N:t) ${(k)PROJ_ALIAS} )
  compadd -a names
}
(( $+functions[compdef] )) && compdef _proj proj projw projk p 2>/dev/null

# ══════════════════════════════════════════════════════════════════════════
# MEVCUT terminali projeye gore boya — tmux'a GIRMEDEN, acik sekmede.
#   cd ile projeye girince: sekme arkaplani proje rengine boyanir + baslik
#   proje adi olur. Projeden cikinca eski haline doner. Otomatiktir;
#   `pj <ad>` sadece "bu terminalde projeye git" kisayoludur.
#   Kapatmak icin: export PROJ_AUTOTHEME=0
# ══════════════════════════════════════════════════════════════════════════

PROJ_AUTOTHEME="${PROJ_AUTOTHEME:-1}"
# Rengin arkaplana karisma orani (%). Dusuk = hafif ton, yuksek = belirgin.
PROJ_BG_STRENGTH="${PROJ_BG_STRENGTH:-35}"

# 256-renk kodu -> "r g b" (0-255, xterm paleti)
__proj_rgb256() {
  local c=$1
  if (( c >= 16 && c <= 231 )); then
    local i=$(( c - 16 )); local -a lv=(0 95 135 175 215 255)
    print -r -- "${lv[$(( i/36 + 1 ))]} ${lv[$(( (i%36)/6 + 1 ))]} ${lv[$(( i%6 + 1 ))]}"
  elif (( c >= 232 )); then
    local g=$(( 8 + (c-232)*10 )); print -r -- "$g $g $g"
  else
    local -a base=("0 0 0" "128 0 0" "0 128 0" "128 128 0" "0 0 128" "128 0 128" "0 128 128" "192 192 192" "128 128 128" "255 0 0" "0 255 0" "255 255 0" "0 0 255" "255 0 255" "0 255 255" "255 255 255")
    print -r -- "${base[$(( c + 1 ))]}"
  fi
}

# Sekmenin ORIJINAL arkaplani (ilk boyamada yakalanir; cikista geri yuklenir)
typeset -g __PROJ_TERM_DEFBG=""
typeset -g __PROJ_CUR_THEME=""

# $1 = proje adi ('' = sifirla)
__proj_theme_apply() {
  local name="$1"
  if [[ -z "$name" ]]; then
    printf '\e]1;\a\e]2;\a'                     # basligi birak (Terminal cwd'ye doner)
    if [[ "$TERM_PROGRAM" == "Apple_Terminal" ]]; then
      if [[ -n "$__PROJ_TERM_DEFBG" ]]; then
        local -a d=( ${=__PROJ_TERM_DEFBG} )
        osascript -e "tell application \"Terminal\" to set background color of selected tab of front window to {${d[1]}, ${d[2]}, ${d[3]}}" >/dev/null 2>&1 &!
      fi
    else
      printf '\e]111\a'                          # OSC 111: varsayilan arkaplana don
    fi
    return 0
  fi

  local color; color=$(__proj_color "$name")
  local -a rgb; rgb=( $(__proj_rgb256 "$color") )
  printf '\e]1;%s\a\e]2;%s\a' "$name" "$name"    # sekme + pencere basligi

  if [[ "$TERM_PROGRAM" == "Apple_Terminal" ]]; then
    # Apple Terminal OSC 11 desteklemez -> AppleScript ile sekmeyi boya.
    # Proje rengi, sekmenin KENDI arkaplanina karistirilir: acik temada pastel,
    # koyu temada koyu ton cikar -> metin her durumda okunur kalir.
    if [[ -z "$__PROJ_TERM_DEFBG" ]]; then
      __PROJ_TERM_DEFBG=$(osascript -e 'tell application "Terminal" to get background color of selected tab of front window' 2>/dev/null | tr -d ',')
      [[ -z "$__PROJ_TERM_DEFBG" ]] && __PROJ_TERM_DEFBG="0 0 0"
    fi
    local -a def=( ${=__PROJ_TERM_DEFBG} )
    local s=$PROJ_BG_STRENGTH
    local r=$(( ( ${def[1]} * (100 - s) + ${rgb[1]} * 257 * s ) / 100 ))
    local g=$(( ( ${def[2]} * (100 - s) + ${rgb[2]} * 257 * s ) / 100 ))
    local b=$(( ( ${def[3]} * (100 - s) + ${rgb[3]} * 257 * s ) / 100 ))
    osascript -e "tell application \"Terminal\" to set background color of selected tab of front window to {$r, $g, $b}" >/dev/null 2>&1 &!
  else
    # iTerm2 / Ghostty / kitty / WezTerm / Alacritty: OSC 11 (koyu ton)
    printf '\e]11;#%02x%02x%02x\a' \
      $(( ${rgb[1]} * s / 100 )) $(( ${rgb[2]} * s / 100 )) $(( ${rgb[3]} * s / 100 ))
  fi
}

# cd hook'u: PWD bir projenin altindaysa boya, degilse sifirla (degisimde bir kez)
__proj_autotheme() {
  [[ -o interactive ]] || return 0               # script/arac kabugu SEKMEYI BOYAMAZ
  [[ "$PROJ_AUTOTHEME" == "1" ]] || return 0
  [[ -n "$TMUX" ]] && return 0                   # tmux'in kendi renkli status'u var
  local name="" p="$PWD/"
  [[ "$p" == "$PROJ_BASE/"?* ]] && name="${${p#$PROJ_BASE/}%%/*}"
  [[ "$name" == "$__PROJ_CUR_THEME" ]] && return 0
  __PROJ_CUR_THEME="$name"
  __proj_theme_apply "$name"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd __proj_autotheme
__proj_autotheme                                  # sekme zaten proje icinde acildiysa hemen boya

# pj <ad> -> BU terminalde projeye gec (boyama chpwd hook'undan otomatik gelir)
pj() {
  local raw="$1"
  [[ -z "$raw" ]] && { echo "kullanim: pj <proje>   (bu terminalde projeye gec + boya)"; return 1; }
  local name; name=$(__proj_resolve "$raw") || return 1
  cd "$PROJ_BASE/$name"
}
(( $+functions[compdef] )) && compdef _proj pj 2>/dev/null

# ══════════════════════════════════════════════════════════════════════════
# ProjBar besleyicisi: her sekme "ben su projedeyim" bilgisini state dosyasina
# yazar; menu cubugundaki ProjBar.app okur. Sekme kapaninca kaydi silinir.
# ══════════════════════════════════════════════════════════════════════════
PROJBAR_STATE="$HOME/.local/state/projbar"

__projbar_write() {
  [[ -o interactive ]] || return 0
  local tty_id="${TTY:t}"
  [[ -z "$tty_id" ]] && return 0
  local name="" p="$PWD/"
  [[ "$p" == "$PROJ_BASE/"?* ]] && name="${${p#$PROJ_BASE/}%%/*}"
  local prev=""
  [[ -f "$PROJBAR_STATE/$tty_id" ]] && prev="${$(head -1 "$PROJBAR_STATE/$tty_id" 2>/dev/null)%%	*}"
  if [[ -n "$name" ]]; then
    mkdir -p "$PROJBAR_STATE" 2>/dev/null
    local -a rgb; rgb=( $(__proj_rgb256 "$(__proj_color "$name")") )
    printf '%s\t#%02x%02x%02x\t%s\n' "$name" "${rgb[1]}" "${rgb[2]}" "${rgb[3]}" "$PWD" \
      > "$PROJBAR_STATE/$tty_id" 2>/dev/null
  else
    rm -f "$PROJBAR_STATE/$tty_id" 2>/dev/null
  fi
  # proje degisti/birakildi -> bu sekmenin eski gorev etiketi artik gecersiz
  [[ -n "$prev" && "$prev" != "$name" ]] && rm -f "$PROJBAR_STATE/task-tty-$tty_id" 2>/dev/null
}
__projbar_cleanup() { [[ -n "${TTY:t}" ]] && rm -f "$PROJBAR_STATE/${TTY:t}" 2>/dev/null }

add-zsh-hook chpwd  __projbar_write
add-zsh-hook zshexit __projbar_cleanup
__projbar_write

# projtask — aktif projenin "su an yapilan is" etiketi (ProjBar rozetinde cikar)
#   projtask onesignal baglantisi   -> etiketi yaz
#   projtask                        -> etiketi goster
#   projtask -                      -> etiketi sil
projtask() {
  # Gorev SEKME-basina (ayni projede iki ayri is = iki sekme = iki etiket).
  local tty_id="${TTY:t}"
  [[ -z "$tty_id" ]] && { echo "tty yok"; return 1; }
  mkdir -p "$PROJBAR_STATE" 2>/dev/null
  if (( $# == 0 )); then
    cat "$PROJBAR_STATE/task-tty-$tty_id" 2>/dev/null
  elif [[ "$1" == "-" ]]; then
    rm -f "$PROJBAR_STATE/task-tty-$tty_id"
  else
    print -r -- "$*" > "$PROJBAR_STATE/task-tty-$tty_id"
  fi
}

# c <ad> -> BU sekmede projeye gec + claude'u baslat (rozet/renk/baslik otomatik).
#   Kullanicinin "yeni proje ac, claude'a soyle" akisinin tek komutu: c ayak
c() {
  local raw="$1"
  [[ -z "$raw" ]] && { echo "kullanim: c <proje>   (bu sekmede cd + claude)"; return 1; }
  local name; name=$(__proj_resolve "$raw") || return 1
  cd "$PROJ_BASE/$name" || return 1
  shift
  claude "$@"
}
(( $+functions[compdef] )) && compdef _proj c 2>/dev/null
