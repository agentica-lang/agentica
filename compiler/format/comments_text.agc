## The text form of the comment attachment: one line per comment, in source order, with where the comment starts, its
## role, the kind of its node and where that node starts, the keyword of a dangling comment that has one, and the
## comment's text. A file that does not lex or parse prints its diagnostic line.

import Diag from "../diagnostics/diagnostic"
import Source from "../syntax/source"
import Lexer from "../syntax/lexer"
import Parser from "../syntax/parser"
import Text from "../syntax/text"
import Comments from "comments"

## The comments of `text` and their places, one per line.
export def attach_text(text: String) -> String
  case Lexer.lex_with_comments(text)
    Diag.Outcome.Failed(problem) -> return Text.diagnostic_line(problem)
    Diag.Outcome.Done(scanned) ->
      case Parser.parse(scanned.tokens, 0)
        Diag.Outcome.Failed(problem) -> return Text.diagnostic_line(problem)
        Diag.Outcome.Done(program) ->
          attachment = Comments.attach(program, scanned.tokens, scanned.comments)
          lines = attachment.comments.map do |placed: Comments.Attached| line_of(attachment, placed) end
          return lines.join("\n")
      end
  end
end

def line_of(attachment: Comments.Attachment, placed: Comments.Attached) -> String
  node = attachment.nodes[placed.node]
  keyword = ""
  if placed.keyword != ""
    keyword = " #{placed.keyword}"
  end

  at = place_text(placed.comment.span.start)
  role = Comments.role_name(placed.role)
  text = Text.quote(placed.comment.text)
  return "#{at} #{role} #{node.kind} #{place_text(node.span.start)}#{keyword} #{text}"
end

def place_text(position: Source.Position) -> String
  return "#{position.line}:#{position.column}"
end
