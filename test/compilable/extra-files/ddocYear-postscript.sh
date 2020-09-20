#!/usr/bin/env bash

source tools/common_funcs.sh

YEAR=$(date +%Y)
# make sure the __YEAR__ placeholder is found in ddocYear.html
grep "__YEAR__" ${EXTRA_FILES}/${TEST_NAME}.html
sed "s/__YEAR__/${YEAR}/" ${EXTRA_FILES}/${TEST_NAME}.html > ${OUTPUT_BASE}.html.1
grep -v "Generated by Ddoc from" ${OUTPUT_BASE}.html > ${OUTPUT_BASE}.html.2
diff -pu --strip-trailing-cr ${OUTPUT_BASE}.html.1 ${OUTPUT_BASE}.html.2

rm_retry ${OUTPUT_BASE}.html{,.1,.2}
