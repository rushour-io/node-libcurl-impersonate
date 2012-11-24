#!/bin/sh

root=`dirname $0`

generate() {
  name=$1
  pattern=$2
  prefix=$3
  echo "generate $root/$name.h"
  (
    echo "// generated by $0 at $(date)"
    echo "CurlOption $name[] = {"
    cat /usr/include/curl/curl.h|perl -ne "/$pattern/i && print \"\t{\\\"\$1\\\", CURL${prefix}_\$1},\n\""
    echo '};'
  ) > $root/$name.h
}
generate integer_options 'CINIT\((\w+).*LONG' OPT
generate string_options  'CINIT\((\w+).*OBJECT' OPT

generate integer_infos 'CURLINFO_(\w+).*LONG' INFO
generate string_infos 'CURLINFO_(\w+).*STRING' INFO
generate double_infos 'CURLINFO_(\w+).*DOUBLE' INFO
