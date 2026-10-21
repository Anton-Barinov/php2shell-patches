PHP_ARG_ENABLE(feedpost, whether to enable feedpost support,
[  --enable-feedpost   Enable feedpost support], no)

if test "$PHP_FEEDPOST" != "no"; then
  PHP_NEW_EXTENSION(feedpost, feedpost.c, $ext_shared)
fi
