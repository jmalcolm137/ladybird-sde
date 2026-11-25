/*
 * Copyright (c) 2026, Ladybird SDE contributors
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <AK/ByteString.h>
#include <AK/String.h>
#include <AK/StringBuilder.h>
#include <LibCore/Environment.h>

namespace LadybirdSDE {

// Escapes '&' to '&&' so untrusted page titles, bookmark names, and <select>
// option labels cannot inject unintended menu accelerator mnemonics in LibGUI.
inline String escape_menu_ampersands(StringView text)
{
    if (!text.contains('&'))
        return String::from_utf8_with_replacement_character(text);
    StringBuilder builder;
    for (char ch : text) {
        if (ch == '&')
            builder.append("&&"sv);
        else
            builder.append(ch);
    }
    return MUST(builder.to_string());
}

// Converts an arbitrary UTF-8 byte sequence into a String without aborting on
// malformed UTF-8 (replacing invalid sequences with U+FFFD).
inline String safe_utf8_string(StringView text)
{
    return String::from_utf8_with_replacement_character(text);
}

// Percent-encodes a value for a GitHub issue URL's query string.
inline String percent_encode_query_value(StringView value)
{
    StringBuilder builder;
    auto const hex = "0123456789ABCDEF"sv;
    for (auto byte : value.bytes()) {
        if ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '.' || byte == '~') {
            builder.append(static_cast<char>(byte));
        } else {
            builder.append('%');
            builder.append(hex[(byte >> 4) & 0xf]);
            builder.append(hex[byte & 0xf]);
        }
    }
    return MUST(builder.to_string());
}

// A prefilled "new issue" page in the Ladybird SDE repository.
inline String github_issue_url(String const& title, String const& body, StringView label)
{
    return String::formatted("https://github.com/jmalcolm137/ladybird-sde/issues/new?labels={}&title={}&body={}",
        percent_encode_query_value(label),
        percent_encode_query_value(title),
        percent_encode_query_value(body))
        .release_value();
}

// Returns the sanitized LADYBIRD_SDE_PROFILE name, rejecting path separators
// or traversal components and falling back to "libgui".
inline ByteString sanitized_profile_name()
{
    auto profile = Core::Environment::get("LADYBIRD_SDE_PROFILE"sv);
    if (!profile.has_value() || profile->is_empty())
        return "libgui";
    auto view = *profile;
    if (view == "."sv || view == ".."sv || view.contains('/') || view.contains('\0'))
        return "libgui";
    return view.to_byte_string();
}

}
