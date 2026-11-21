#!/bin/sh
# ============================================================================
# Alpindroid: terminal polish — colours, usable fonts, console font
#
# Runs on the board (or in a chroot of the target rootfs) as root. Idempotent.
#
# Why: the base Alpine rootfs ships with no fonts at all (fontconfig is there
# because weston-terminal links it, but `fc-list` is empty) and a bare prompt
# with no colour. That makes the HDMI console and weston-terminal hard to use
# and makes CJK text render as boxes.
#
# What it installs
#   bash                3.5 MB   — optional interactive shell (ash stays default)
#   font-noto           9.2 MB   — Sans / Serif / Sans Mono
#   font-adobe-source-code-pro  1.6 MB — proper monospace for the terminal
#   font-wqy-zenhei     16 MB   — CJK coverage (much smaller than font-noto-cjk's 88 MB)
#   consolefont-spleen  65 KB   — readable console font for the framebuffer tty
#
# What it configures
#   /etc/profile.d/alpindroid-color.sh   PS1 + LS_COLORS + aliases (ash and bash)
#   /etc/inputrc                         bash history/completion behaviour
#   /etc/fonts/local.conf                monospace/sans fallback incl. CJK
#   /etc/conf.d/consolefont              framebuffer console font
#
# Usage (on the board, as root):
#   sh install-terminal-polish.sh
#
# Optional environment:
#   BIG_CJK=1   install font-noto-cjk (88 MB) instead of font-wqy-zenhei
#   WITH_BASH=0 skip the bash package
# ============================================================================
set -e

BIG_CJK="${BIG_CJK:-0}"
WITH_BASH="${WITH_BASH:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"

# ---------------------------------------------------------------- 1. packages
say "1/5 packages"
if grep -q 'dl-cdn.alpinelinux.org' /etc/apk/repositories 2>/dev/null; then
    echo "  switching to mirrors.aliyun.com"
    sed -i 's|https\?://dl-cdn.alpinelinux.org|https://mirrors.aliyun.com|' /etc/apk/repositories
fi

PKGS="font-noto font-adobe-source-code-pro consolefont-spleen"
if [ "$WITH_BASH" = "1" ]; then
    PKGS="$PKGS bash"
fi
if [ "$BIG_CJK" = "1" ]; then
    PKGS="$PKGS font-noto-cjk"
else
    PKGS="$PKGS font-wqy-zenhei"
fi
# shellcheck disable=SC2086
apk add --no-cache $PKGS
fc-cache -f >/dev/null 2>&1 || true
echo "  fonts now visible to fontconfig: $(fc-list 2>/dev/null | wc -l)"

# ------------------------------------------------------------- 2. shell colour
say "2/5 shell colour (/etc/profile.d/alpindroid-color.sh)"
cat > /etc/profile.d/alpindroid-color.sh <<'EOF'
# Alpindroid: coloured prompt + coloured ls/grep. Sourced by ash (login shells
# via /etc/profile) and by bash (non-login shells read it through the guard at
# the bottom of this file when BASH_ENV is set, or manually: . /etc/profile.d/alpindroid-color.sh).
#
# ash and bash differ: bash needs \[ \] around non-printing sequences, busybox
# ash does not understand them and would print them literally.

# ---- colours
if [ -n "${BASH_VERSION:-}" ]; then
    # bash: wrap escapes in \[ \]
    if [ "$(id -u)" -eq 0 ]; then
        PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
    else
        PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
    fi
else
    # busybox ash
    if [ "$(id -u)" -eq 0 ]; then
        PS1='\e[1;31m\u@\h\e[0m:\e[1;34m\w\e[0m# '
    else
        PS1='\e[1;32m\u@\h\e[0m:\e[1;34m\w\e[0m\$ '
    fi
fi
export PS1

# ---- LS_COLORS (no dircolors on Alpine/busybox, so spell it out)
LS_COLORS='rs=0:di=1;34:ln=1;36:mh=00:pi=33:so=1;35:do=1;35:bd=1;33:cd=1;33'
LS_COLORS="$LS_COLORS:or=1;31:mi=1;31:su=37;41:sg=30;43:ca=30;41:tw=30;42:ow=34;42:st=37;44"
LS_COLORS="$LS_COLORS:ex=1;32"
LS_COLORS="$LS_COLORS:*.tar=1;31:*.tgz=1;31:*.gz=1;31:*.bz2=1;31:*.xz=1;31:*.zst=1;31"
LS_COLORS="$LS_COLORS:*.zip=1;31:*.7z=1;31:*.img=1;31:*.ko=1;35:*.patch=1;33:*.diff=1;33"
LS_COLORS="$LS_COLORS:*.c=36:*.h=36:*.sh=32:*.py=33:*.md=1;35:*.ini=35:*.conf=35:*.service=35"
export LS_COLORS

# ---- aliases (busybox ls/grep both understand --color)
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias egrep='grep -E --color=auto'
alias fgrep='grep -F --color=auto'
alias grep='grep --color=auto'

# reasonable defaults for interactive use
HISTSIZE=1000
export HISTSIZE
EOF

# ------------------------------------------------------------- 3. inputrc
say "3/5 /etc/inputrc (bash)"
if [ ! -f /etc/inputrc ]; then
    cat > /etc/inputrc <<'EOF'
# Alpindroid: bash readline defaults
set bell-style none
set completion-ignore-case on
set show-all-if-ambiguous on
set colored-stats on
set menu-complete-display-prefix on
"\e[A": history-search-backward
"\e[B": history-search-forward
EOF
    echo "  written"
else
    echo "  keeping existing /etc/inputrc"
fi

# ------------------------------------------------------------- 4. fontconfig
say "4/5 /etc/fonts/local.conf (monospace + CJK fallback)"
mkdir -p /etc/fonts
cat > /etc/fonts/local.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- Alpindroid: pick a real monospace for terminals and keep CJK renderable.
     "prepend ... strong" is needed because WenQuanYi Zen Hei Mono advertises
     itself as a monospace family too and would otherwise win the generic match. -->
<fontconfig>
  <match target="pattern">
    <test qual="any" name="family"><string>monospace</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>Source Code Pro</string>
      <string>Noto Sans Mono</string>
      <string>WenQuanYi Zen Hei Mono</string>
    </edit>
  </match>
  <match target="pattern">
    <test qual="any" name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>Noto Sans</string>
      <string>WenQuanYi Zen Hei</string>
    </edit>
  </match>
</fontconfig>
EOF
fc-cache -f >/dev/null 2>&1 || true
echo "  monospace match: $(fc-match monospace 2>/dev/null)"

# ------------------------------------------------------------- 5. console font
say "5/5 framebuffer console font"
CF=$(ls /usr/share/consolefonts/*.psfu.gz 2>/dev/null | head -n 1)
if [ -n "$CF" ]; then
    mkdir -p /etc/conf.d
    cat > /etc/conf.d/consolefont <<EOF
# Alpindroid: console font for the framebuffer tty (installed by install-terminal-polish.sh)
consolefont="$(basename "$CF")"
consoletranslation=""
EOF
    rc-update add consolefont boot >/dev/null 2>&1 || true
    rc-service consolefont start >/dev/null 2>&1 || true
    echo "  consolefont=$(basename "$CF")"
else
    echo "  WARN no *.psfu.gz in /usr/share/consolefonts"
fi

say "done"
cat <<'EOF'
Take effect:
  * open a new login shell (or `exec $SHELL`) for the coloured prompt;
  * restarted weston-terminal picks up the new fontconfig rules;
  * the framebuffer console font applies on the next VT switch (`consolefont`
    service) or at the next boot.

Optional: switch the login shell of the desktop user to bash
  apk add bash && chsh -s /bin/bash <user>
EOF
