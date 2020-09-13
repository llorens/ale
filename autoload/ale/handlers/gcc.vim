scriptencoding utf-8
" Author: w0rp <devw0rp@gmail.com>
" Description: This file defines a handler function which ought to work for
" any program which outputs errors in the format that GCC uses.

let s:pragma_error = '#pragma once in main file'

" Look for lines like the following.
"
" <stdin>:8:5: warning: conversion lacks type at end of format [-Wformat=]
" <stdin>:10:27: error: invalid operands to binary - (have ‘int’ and ‘char *’)
" -:189:7: note: $/${} is unnecessary on arithmetic variables. [SC2004]
let s:pattern = '\v^([a-zA-Z]?:?[^:]+):(\d+):(\d+)?:? ([^:]+): (.+)$'
let s:inline_pattern = '\v inlined from .* at \<stdin\>:(\d+):(\d+):$'

function! s:IsHeaderFile(filename) abort
    return a:filename =~? '\v\.(h|hpp)$'
endfunction

function! s:RemoveUnicodeQuotes(text) abort
    let l:text = a:text
    let l:text = substitute(l:text, '[`´‘’]', '''', 'g')
    let l:text = substitute(l:text, '\v\\u2018([^\\]+)\\u2019', '''\1''', 'g')
    let l:text = substitute(l:text, '[“”]', '"', 'g')

    return l:text
endfunction

function! s:ParseInlinedFunctionProblems(buffer, lines) abort
    let l:output = []
    let l:pos_match = []

    for l:line in a:lines
        let l:match = matchlist(l:line, s:pattern)

        if !empty(l:match) && !empty(l:pos_match)
            call add(l:output, {
            \   'lnum': str2nr(l:pos_match[1]),
            \   'col': str2nr(l:pos_match[2]),
            \   'type': (l:match[4] is# 'error' || l:match[4] is# 'fatal error') ? 'E' : 'W',
            \   'text': s:RemoveUnicodeQuotes(l:match[5]),
            \})
        endif

        let l:pos_match = matchlist(l:line, s:inline_pattern)
    endfor

    return l:output
endfunction

" Report problems inside of header files just for gcc and clang
"
" Output from clang:
"     In file included from <stdin>:1:
"     ./header_1.hpp:1:2: warning: A warning. [-W#warnings]
"     #warning A warning.
"      ^
"     In file included from <stdin>:2:
"     In file included from ./header_recursive.hpp:1:
"     In file included from ./header_recursive_1.hpp:1:
"     ./header_recursive_2.hpp:1:2: warning: Another warning. [-W#warnings]
"     #warning Another warning.
"      ^
"     In file included from <stdin>:3:
"     ./header_2.hpp:1:2: warning: A warning - again. [-W#warnings]
"     #warning A warning - again.
"      ^
"     3 warnings generated.
" Output from gcc:
"     header_1.hpp:1:2: warning: #warning A warning. [-Wcpp]
"         1 | #warning A warning.
"           |  ^~~~~~~
"     In file included from header_recursive_1.hpp:1,
"                      from header_recursive.hpp:1,
"                      from <stdin>:2:
"     header_recursive_2.hpp:1:2: warning: #warning Another warning. [-Wcpp]
"         1 | #warning Another warning.
"           |  ^~~~~~~
"     In file included from <stdin>:3:
"     header_2.hpp:1:2: warning: #warning A warning - again. [-Wcpp]
"         1 | #warning A warning - again.
"           |  ^~~~~~~
" Common denominator:
" - we start collecting problem information when '\v^In file included from'
"   matches,
" - we assume the problem report is complete when s:pattern matches. The file
"   name should not be '<stdin>' then.
function! s:ParseProblemsInHeaders(buffer, lines) abort
    let l:output = []
    let l:include_item = {}

    for l:line in a:lines[: -2]
        let l:include_match = matchlist(l:line, '\v^In file included from')

        if !empty(l:include_item)
            let l:include_item.detail .= "\n" . l:line
            let l:pattern_match = matchlist(l:line, s:pattern)

            if !empty(l:pattern_match) && l:pattern_match[1] isnot# '<stdin>'
                if has_key(l:include_item, 'lnum')
                    call add(l:output, l:include_item)
                endif

                let l:include_item = {}

                continue
            endif
        endif

        if !empty(l:include_match)
            if empty(l:include_item)
                let l:include_item = {
                \   'text': 'Error found in header. See :ALEDetail',
                \   'detail': l:line,
                \}
            endif
        endif

        if !empty(l:include_item)
            let l:stdin_match = matchlist(l:line, '\vfrom \<stdin\>:(\d+):(\d*):?$')

            if !empty(l:stdin_match)
                let l:include_item.lnum = str2nr(l:stdin_match[1])

                if str2nr(l:stdin_match[2])
                    let l:include_item.col = str2nr(l:stdin_match[2])
                endif
            endif
        endif
    endfor

    if !empty(l:include_item) && has_key(l:include_item, 'lnum')
        call add(l:output, l:include_item)
    endif

    return l:output
endfunction

function! ale#handlers#gcc#HandleGCCFormat(buffer, lines) abort
    let l:output = []

    for l:match in ale#util#GetMatches(a:lines, s:pattern)
        " Filter out the pragma errors
        if s:IsHeaderFile(bufname(bufnr('')))
        \&& l:match[5][:len(s:pragma_error) - 1] is# s:pragma_error
            continue
        endif

        " If the 'error type' is a note, make it detail related to
        " the previous error parsed in output
        if l:match[4] is# 'note'
            if !empty(l:output)
                if !has_key(l:output[-1], 'detail')
                    let l:output[-1].detail = l:output[-1].text
                endif

                let l:output[-1].detail = l:output[-1].detail . "\n"
                \   . s:RemoveUnicodeQuotes(l:match[0])
            endif

            continue
        endif

        let l:item = {
        \   'lnum': str2nr(l:match[2]),
        \   'type': (l:match[4] is# 'error' || l:match[4] is# 'fatal error') ? 'E' : 'W',
        \   'text': s:RemoveUnicodeQuotes(l:match[5]),
        \}

        if !empty(l:match[3])
            let l:item.col = str2nr(l:match[3])
        endif

        " If the filename is something like <stdin>, <nofile> or -, then
        " this is an error for the file we checked.
        if l:match[1] isnot# '-' && l:match[1][0] isnot# '<'
            let l:item['filename'] = l:match[1]
        endif

        call add(l:output, l:item)
    endfor

    return l:output
endfunction

" Handle problems with the GCC format, but report problems inside of headers.
function! ale#handlers#gcc#HandleGCCFormatWithIncludes(buffer, lines) abort
    let l:output = ale#handlers#gcc#HandleGCCFormat(a:buffer, a:lines)

    call extend(l:output, s:ParseInlinedFunctionProblems(a:buffer, a:lines))
    call extend(l:output, s:ParseProblemsInHeaders(a:buffer, a:lines))

    return l:output
endfunction
