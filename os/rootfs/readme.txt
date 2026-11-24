roco_os

This is a small RV32 supervisor-mode operating system for the roco
dual-hart SoC. The filesystem lives in SDRAM and is rebuilt from the
kernel image at boot, so edits survive until the next reset.

Try:
  ls /
  cat /readme.txt
  mkdir /home/user/work
  cd /home/user
  pwd
  edit /home/user/notes.txt
  df
