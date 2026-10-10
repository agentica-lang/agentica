#include "agc.h"

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

void agc_print_diagnostic(FILE *err, const agc_program *p, const agc_outcome *outcome) {
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
  fflush(err);
}
