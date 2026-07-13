#!/bin/zsh
# ProjBar'ı derle, .app paketle, ~/Applications'a kur ve başlat.
set -e
cd "$(dirname "$0")"

echo "▸ derleniyor..."
# -Osize + strip: bellek ayak izini küçült (kullanıcı isteği: <38 MB)
swiftc -Osize -framework AppKit -framework Carbon main.swift -o ProjBar
strip -x ProjBar 2>/dev/null || true

echo "▸ paketleniyor..."
rm -rf ProjBar.app
mkdir -p ProjBar.app/Contents/MacOS
cp Info.plist ProjBar.app/Contents/
mv ProjBar ProjBar.app/Contents/MacOS/

# Kalıcı kimlikle imzala: ad-hoc imza her derlemede değiştiği için macOS
# otomasyon izinlerini her rebuild'de yeniden soruyor. Varsa ilk Apple
# Development sertifikası otomatik kullanılır (PROJBAR_SIGN_ID ile
# sabitlenebilir); yoksa ad-hoc'a düşer.
IDENTITY="${PROJBAR_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ]; then
  codesign --force -s "$IDENTITY" ProjBar.app
else
  codesign --force -s - ProjBar.app
fi

echo "▸ kuruluyor..."
mkdir -p "$HOME/Applications"
# Çalışan örneği kapat, eskisini değiştir
pkill -x ProjBar 2>/dev/null || true
rm -rf "$HOME/Applications/ProjBar.app"
cp -R ProjBar.app "$HOME/Applications/ProjBar.app"

echo "▸ başlatılıyor..."
open "$HOME/Applications/ProjBar.app"
echo "✓ ProjBar menü çubuğunda. İlk Terminal erişiminde macOS izin soracak — 'İzin Ver' de."
