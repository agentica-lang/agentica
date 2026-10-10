#include "agc.h"

#include <string.h>

static size_t char_width(uint8_t c) {
  if (c < 0x80) return 1;
  if (c < 0xE0) return 2;
  if (c < 0xF0) return 3;
  return 4;
}

static void put_text(FILE *err, const char *text, size_t len) {
  for (size_t i = 0; i < len; i++) {
    uint8_t c = (uint8_t)text[i];
    fputc((c < 0x20 && c != '\t') || c == 0x7F ? '?' : c, err);
  }
}

static void put_json(FILE *err, const char *text, size_t len) {
  fputc('"', err);
  for (size_t i = 0; i < len; i++) {
    uint8_t c = (uint8_t)text[i];
    switch (c) {
      case '"': fputs("\\\"", err); break;
      case '\\': fputs("\\\\", err); break;
      case '\b': fputs("\\b", err); break;
      case '\f': fputs("\\f", err); break;
      case '\n': fputs("\\n", err); break;
      case '\r': fputs("\\r", err); break;
      case '\t': fputs("\\t", err); break;
      default:
        if (c < 0x20 || c == 0x7F)
          fprintf(err, "\\u%04x", (unsigned)c);
        else
          fputc(c, err);
    }
  }
  fputc('"', err);
}

static bool trimmed(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r'; }

static void print_json(FILE *err, const agc_program *p, const agc_outcome *outcome) {
  const agc_span *span = &p->spans[outcome->span];
  const agc_string *name = p->sources[span->source].name;
  fputs("{\"code\":", err);
  put_json(err, outcome->code, strlen(outcome->code));
  fputs(",\"file\":", err);
  put_json(err, name->data, name->bytes);
  fputs(",\"message\":", err);
  put_json(err, outcome->message, strlen(outcome->message));
  fprintf(err, ",\"range\":{\"end\":{\"column\":%u,\"line\":%u},\"start\":{\"column\":%u,\"line\":%u}}}\n",
          (unsigned)span->end_column, (unsigned)span->end_line, (unsigned)span->start_column,
          (unsigned)span->start_line);
}

static void print_ai(FILE *err, const agc_program *p, const agc_outcome *outcome) {
  const agc_span *span = &p->spans[outcome->span];
  const agc_source *source = &p->sources[span->source];
  const char *text = source->text->data;
  uint32_t line = span->start_line;
  size_t start = source->line_start[line - 1];
  size_t end = line < source->lines ? source->line_start[line] - 1 : source->text->bytes;
  while (start < end && trimmed(text[start])) start++;
  while (end > start && trimmed(text[end - 1])) end--;
  fprintf(err, "check failed: 1 error\n\n[%s]\n  message: %s\n  at: ", outcome->code, outcome->message);
  put_text(err, source->name->data, source->name->bytes);
  fprintf(err, ":%u:%u\n  source: ", (unsigned)line, (unsigned)span->start_column);
  put_text(err, text + start, end - start);
  fputc('\n', err);
}

static void print_plain(FILE *err, const agc_program *p, const agc_outcome *outcome) {
  const agc_span *span = &p->spans[outcome->span];
  const agc_source *source = &p->sources[span->source];
  const char *text = source->text->data;
  uint32_t line = span->start_line;
  uint32_t column = span->start_column;
  size_t start = source->line_start[line - 1];
  size_t end = line < source->lines ? source->line_start[line] - 1 : source->text->bytes;
  size_t chars = source->line_chars[line - 1];
  if (end > start && text[end - 1] == '\r') {
    end--;
    chars--;
  }
  size_t room = chars > column - 1 ? chars - (column - 1) : 1;
  size_t wanted = span->end_line == line ? span->end_column - column : room;
  size_t width = wanted < room ? wanted : room;
  if (width < 1) width = 1;
  int gutter = snprintf(NULL, 0, "%u", (unsigned)line);

  put_text(err, source->name->data, source->name->bytes);
  fprintf(err, ":%u:%u error[%s]\n%s\n\n%u | ", (unsigned)line, (unsigned)column, outcome->code,
          outcome->message, (unsigned)line);
  put_text(err, text + start, end - start);
  fprintf(err, "\n%*s | ", gutter, "");
  size_t at = start;
  for (size_t i = 0; i < column - 1; i++) {
    if (at < end) {
      fputc(text[at] == '\t' ? '\t' : ' ', err);
      at += char_width((uint8_t)text[at]);
    } else {
      fputc(' ', err);
    }
  }
  for (size_t i = 0; i < width; i++) fputc('^', err);
  fputc('\n', err);
}

void agc_print_diagnostic(FILE *err, const agc_program *p, const agc_outcome *outcome, agc_style style) {
  if (style == AGC_STYLE_JSON)
    print_json(err, p, outcome);
  else if (style == AGC_STYLE_AI)
    print_ai(err, p, outcome);
  else
    print_plain(err, p, outcome);
  fflush(err);
}
