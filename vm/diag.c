#include "agc.h"

#include <inttypes.h>
#include <string.h>

static const char in_task[] = " in a task";

typedef struct {
  const char *text;
  size_t start, end, chars;
} source_line;

static source_line line_of(const agc_source *source, uint32_t line) {
  source_line l;
  l.text = source->text->data;
  l.start = source->line_start[line - 1];
  l.end = line < source->lines ? source->line_start[line] - 1 : source->text->bytes;
  l.chars = source->line_chars[line - 1];
  if (l.end > l.start && l.text[l.end - 1] == '\r') {
    l.end--;
    l.chars--;
  }
  return l;
}

static void put_text(FILE *err, const char *text, size_t len) {
  if (len) fwrite(text, 1, len, err);
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

static void print_json(FILE *err, const agc_program *p, const agc_outcome *outcome, bool task) {
  const agc_span *span = &p->spans[outcome->span];
  const agc_string *name = p->sources[span->source].name;
  fputs("{\"code\":", err);
  put_json(err, outcome->code, strlen(outcome->code));
  fputs(",\"file\":", err);
  put_json(err, name->data, name->bytes);
  fputs(",\"message\":", err);
  put_json(err, outcome->message, outcome->message_len);
  fprintf(err, ",\"range\":{\"end\":{\"column\":%u,\"line\":%u},\"start\":{\"column\":%u,\"line\":%u}}%s}\n",
          (unsigned)span->end_column, (unsigned)span->end_line, (unsigned)span->start_column,
          (unsigned)span->start_line, task ? ",\"task\":true" : "");
}

static void print_ai(FILE *err, const agc_program *p, const agc_outcome *outcome, bool task) {
  const agc_span *span = &p->spans[outcome->span];
  const agc_source *source = &p->sources[span->source];
  source_line l = line_of(source, span->start_line);
  while (l.start < l.end && trimmed(l.text[l.start])) l.start++;
  while (l.end > l.start && trimmed(l.text[l.end - 1])) l.end--;
  if (!task) fputs("check failed: 1 error\n\n", err);
  fprintf(err, "[%s]%s\n  message: ", outcome->code, task ? in_task : "");
  put_text(err, outcome->message, outcome->message_len);
  fputs("\n  at: ", err);
  put_text(err, source->name->data, source->name->bytes);
  fprintf(err, ":%u:%u\n  source: ", (unsigned)span->start_line, (unsigned)span->start_column);
  put_text(err, l.text + l.start, l.end - l.start);
  fputc('\n', err);
}

static void print_plain(FILE *err, const agc_program *p, const agc_outcome *outcome, bool task) {
  const agc_span *span = &p->spans[outcome->span];
  const agc_source *source = &p->sources[span->source];
  uint32_t line = span->start_line;
  uint32_t column = span->start_column;
  source_line l = line_of(source, line);
  size_t room = l.chars > column - 1 ? l.chars - (column - 1) : 1;
  size_t wanted = span->end_line == line ? span->end_column - column : room;
  size_t width = wanted < room ? wanted : room;
  if (width < 1) width = 1;
  int gutter = snprintf(NULL, 0, "%u", (unsigned)line);

  put_text(err, source->name->data, source->name->bytes);
  fprintf(err, ":%u:%u error[%s]%s\n", (unsigned)line, (unsigned)column, outcome->code, task ? in_task : "");
  put_text(err, outcome->message, outcome->message_len);
  fprintf(err, "\n\n%u | ", (unsigned)line);
  put_text(err, l.text + l.start, l.end - l.start);
  fprintf(err, "\n%*s | ", gutter, "");
  size_t at = l.start;
  for (size_t i = 0; i < column - 1; i++) {
    if (at < l.end) {
      fputc(l.text[at] == '\t' ? '\t' : ' ', err);
      at += agc_utf8_width((uint8_t)l.text[at]);
    } else {
      fputc(' ', err);
    }
  }
  for (size_t i = 0; i < width; i++) fputc('^', err);
  fputc('\n', err);
}

void agc_print_diagnostic(FILE *err, const agc_program *p, const agc_outcome *outcome, agc_style style, bool task) {
  if (style == AGC_STYLE_JSON)
    print_json(err, p, outcome, task);
  else if (style == AGC_STYLE_AI)
    print_ai(err, p, outcome, task);
  else
    print_plain(err, p, outcome, task);
  fflush(err);
}

static size_t breaks(const char *text, size_t len) {
  size_t n = 0;
  for (size_t i = 0; i < len; i++) n += text[i] == '\n' || text[i] == '\r';
  return n;
}

static char *put_line(char *put, const char *text, size_t len) {
  for (size_t i = 0; i < len; i++) {
    if (text[i] == '\n' || text[i] == '\r') {
      *put++ = '\\';
      *put++ = text[i] == '\n' ? 'n' : 'r';
    } else {
      *put++ = text[i];
    }
  }
  return put;
}

/* One line: line breaks in the path or the message are written as \n, \r. */
agc_string *agc_crash_text(const agc_program *p, const agc_outcome *outcome) {
  const agc_span *span = &p->spans[outcome->span];
  const agc_string *name = p->sources[span->source].name;
  char at[48];
  int n = snprintf(at, sizeof at, ":%u:%u: ", (unsigned)span->start_line, (unsigned)span->start_column);
  static const char head[] = "task crashed: ", mid[] = " at ";
  size_t code = strlen(outcome->code);
  size_t extra = breaks(name->data, name->bytes) + breaks(outcome->message, outcome->message_len);
  size_t len = agc_size_add(agc_size_add(sizeof head - 1 + code + sizeof mid - 1, name->bytes),
                            agc_size_add(agc_size_add((size_t)n, outcome->message_len), extra));
  char *text = agc_alloc_atomic(len);
  char *put = text;
  memcpy(put, head, sizeof head - 1);
  put += sizeof head - 1;
  memcpy(put, outcome->code, code);
  put += code;
  memcpy(put, mid, sizeof mid - 1);
  put += sizeof mid - 1;
  put = put_line(put, name->data, name->bytes);
  memcpy(put, at, (size_t)n);
  put += n;
  put_line(put, outcome->message, outcome->message_len);
  return agc_utf8_decode((const uint8_t *)text, len, "\xEF\xBF\xBD", false);
}

void agc_print_unobserved(FILE *err, uint64_t count, const agc_string *first, agc_style style) {
  if (style == AGC_STYLE_JSON) {
    fprintf(err, "{\"unobserved_crashes\":%" PRIu64 ",\"first\":", count);
    put_json(err, first->data, first->bytes);
    fputs("}\n", err);
  } else {
    fprintf(err, "%" PRIu64 " task %s not observed; first: ", count, count == 1 ? "crash was" : "crashes were");
    put_text(err, first->data, first->bytes);
    fputc('\n', err);
  }
  fflush(err);
}

void agc_print_flush_failed(FILE *err, const char *code, const char *message, size_t len, agc_style style) {
  if (style == AGC_STYLE_JSON)
    fprintf(err, "{\"flush_failed\":\"%s\",\"warning\":\"file data may not be written\"}\n", code);
  else
    fprintf(err, "agentica: file data may not be written: the flush failed (%s: %.*s)\n", code, (int)len, message);
  fflush(err);
}

void agc_print_flush_timeout(FILE *err, int64_t ms, agc_style style) {
  if (style == AGC_STYLE_JSON)
    fprintf(err, "{\"flush_timeout_ms\":%" PRId64 ",\"warning\":\"file data may not be written\"}\n", ms);
  else
    fprintf(err, "agentica: file data may not be written: the flush took longer than %" PRId64 " ms\n", ms);
  fflush(err);
}
