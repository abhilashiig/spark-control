Spark Control — green bolt app icon

Appearances
  default   Fresh green squircle, raised green glass key, white bolt
  dark      Dark glass, glowing green bolt
  tinted    Single tone for macOS tinted mode
  clear     Translucent glass for clear mode

svg/  Vector masters on Apple's 1024 grid (824 px squircle body).
      *-small.svg are tuned for 16 and 32 px: the inner key is dropped
      and the bolt is enlarged so it stays crisp.

png/  One .iconset folder per appearance: 16-1024 px at 1x and @2x,
      transparent background. 16, 32 and 16@2x come from the small master.
      Build an .icns on a Mac with:  iconutil -c icns png/default.iconset
      (iconutil ignores the extra 64x64 files.)
