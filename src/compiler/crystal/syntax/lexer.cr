require "./token"
require "../exception"

module Crystal
  class Lexer
    property? doc_enabled
    property? comments_enabled
    property? count_whitespace

    def initialize(string)
      @reader = CharReader.new(string)
      @token = Token.new
      @line_number = 1
      @column_number = 1
      @filename = ""
      @wants_regex = true
      @doc_enabled = false
      @comments_enabled = false
      @count_whitespace = false
      @slash_is_regex = true
    end

    def filename=(filename)
      @filename = filename
    end

    def next_token
      reset_token

      start = current_pos

      # Skip comments
      if current_char == '#'
        char = next_char_no_column_increment

        # Check #<loc:"file",line,column> pragma comment
        if char == '<' &&
          (char = next_char_no_column_increment) == 'l' &&
          (char = next_char_no_column_increment) == 'o' &&
          (char = next_char_no_column_increment) == 'c' &&
          (char = next_char_no_column_increment) == ':' &&
          (char = next_char_no_column_increment) == '"'
          next_char_no_column_increment
          consume_loc_pragma
        else
          if @doc_enabled
            consume_doc
          elsif @comments_enabled
            return consume_comment(start)
          else
            skip_comment
          end
        end
      end

      reset_regex_flags = true

      case current_char
      when '\0'
        @token.type = :EOF
      when ' ', '\t'
        consume_whitespace
        reset_regex_flags = false
      when '\\'
        if next_char == '\n'
          @line_number += 1
          @column_number = 1
          @token.passed_backslash_newline = true
          consume_whitespace
          reset_regex_flags = false
        else
          unknown_token
        end
      when '\n'
        @token.type = :NEWLINE
        next_char
        @line_number += 1
        @column_number = 1
        reset_regex_flags = false
        consume_newlines
      when '\r'
        if next_char == '\n'
          next_char
          @token.type = :NEWLINE
          @line_number += 1
          @column_number = 1
          consume_newlines
        else
          raise "expected '\\n' after '\\r'"
        end
      when '='
        case next_char
        when '='
          case next_char
          when '='
            next_char :"==="
          else
            @token.type = :"=="
          end
        when '>'
          next_char :"=>"
        when '~'
          next_char :"=~"
        else
          @token.type = :"="
        end
      when '!'
        case next_char
        when '='
          next_char :"!="
        else
          @token.type = :"!"
        end
      when '<'
        case next_char
        when '='
          case next_char
          when '>'
            next_char :"<=>"
          else
            @token.type = :"<="
          end
        when '<'
          case next_char
          when '='
            next_char :"<<="
          when '-'
            here = StringIO.new(20)
            here_start = 0

            while true
              case char = next_char
              when '\n'
                @line_number += 1
                @column_number = 0
                next_char
                here_start = current_pos
                break
              else
                here << char
              end
            end

            here = here.to_s

            while true
              case char = next_char
              when '\0'
                raise "unterminated heredoc"
              when '\n'
                @line_number += 1
                @column_number = 0
                here_end = current_pos
                is_here  = false
                here.each_char do |c|
                  unless c == next_char
                    is_here = false
                    break
                  end
                  is_here = true
                end

                if is_here
                  peek = peek_next_char
                  if peek == '\n' || peek == '\0'
                    next_char
                    @token.value = string_range(here_start, here_end)
                    @token.type = :STRING
                    break
                  end
                end
              end
            end
          else
            @token.type = :"<<"
          end
        else
          @token.type = :"<"
        end
      when '>'
        case next_char
        when '='
          next_char :">="
        when '>'
          case next_char
          when '='
            next_char :">>="
          else
            @token.type = :">>"
          end
        else
          @token.type = :">"
        end
      when '+'
        start = current_pos
        case next_char
        when '='
          next_char :"+="
        when '0'
          scan_zero_number(start)
        when '1', '2', '3', '4', '5', '6', '7', '8', '9'
          scan_number(start)
        else
          @token.type = :"+"
        end
      when '-'
        start = current_pos
        case next_char
        when '='
          next_char :"-="
        when '>'
          next_char :"->"
        when '0'
          scan_zero_number start, negative: true
        when '1', '2', '3', '4', '5', '6', '7', '8', '9'
          scan_number start, negative: true
        else
          @token.type = :"-"
        end
      when '*'
        case next_char
        when '='
          next_char :"*="
        when '*'
          case next_char
          when '='
            next_char :"**="
          else
            @token.type = :"**"
          end
        else
          @token.type = :"*"
        end
      when '/'
        line = @line_number
        column = @column_number
        char = next_char
        if char == '='
          next_char :"/="
        elsif @slash_is_regex
          @token.type = :DELIMITER_START
          @token.delimiter_state = Token::DelimiterState.new(:regex, '/', '/', 0)
        elsif char.whitespace? || char == '\0' || char == ';'
          @token.type = :"/"
        elsif @wants_regex
          @token.type = :DELIMITER_START
          @token.delimiter_state = Token::DelimiterState.new(:regex, '/', '/', 0)
        else
          @token.type = :"/"
        end
      when '%'
        case next_char
        when '='
          next_char :"%="
        when '(', '[', '{', '<'
          delimited_pair :string, current_char, closing_char
        when 'i'
          case peek_next_char
          when '(', '{', '[', '<'
            start_char = next_char
            next_char :SYMBOL_ARRAY_START
            @token.delimiter_state = Token::DelimiterState.new(:symbol_array, start_char, closing_char(start_char), 0)
          else
            @token.type = :"%"
          end
        when 'r'
          case next_char
          when '(', '[', '{', '<'
            delimited_pair :regex, current_char, closing_char
          else
            raise "unknown %r char"
          end
        when 'x'
          case next_char
          when '(', '[', '{', '<'
            delimited_pair :command, current_char, closing_char
          else
            raise "unknown %x char"
          end
        when 'w'
          case peek_next_char
          when '(', '{', '[', '<'
            start_char = next_char
            next_char :STRING_ARRAY_START
            @token.delimiter_state = Token::DelimiterState.new(:string_array, start_char, closing_char(start_char), 0)
          else
            @token.type = :"%"
          end
        when '}'
          next_char :"%}"
        else
          @token.type = :"%"
        end
      when '(' then next_char :"("
      when ')' then next_char :")"
      when '{'
        char = next_char
        case char
        when '%'
          next_char :"{%"
        when '{'
          next_char :"{{"
        else
          @token.type = :"{"
        end
      when '}' then next_char :"}"
      when '['
        case next_char
        when ']'
          case next_char
          when '='
            next_char :"[]="
          when '?'
            next_char :"[]?"
          else
            @token.type = :"[]"
          end
        else
          @token.type = :"["
        end
      when ']' then next_char :"]"
      when ',' then next_char :","
      when '?' then next_char :"?"
      when ';' then
        reset_regex_flags = false
        next_char :";"
      when ':'
        char = next_char
        case char
        when ':'
          next_char :"::"
        when '+'
          next_char_and_symbol "+"
        when '-'
          next_char_and_symbol "-"
        when '*'
          if next_char == '*'
            next_char_and_symbol "**"
          else
            symbol "*"
          end
        when '/'
          next_char_and_symbol "/"
        when '='
          case next_char
          when '='
            if next_char == '='
              next_char_and_symbol "==="
            else
              symbol "=="
            end
          when '~'
            next_char_and_symbol "=~"
          else
            unknown_token
          end
        when '!'
          case next_char
          when '='
            next_char_and_symbol "!="
          when '~'
            next_char_and_symbol "!~"
          else
            symbol "!"
          end
        when '<'
          case next_char
          when '='
            if next_char == '>'
              next_char_and_symbol "<=>"
            else
              symbol "<="
            end
          when '<'
            next_char_and_symbol "<<"
          else
            symbol "<"
          end
        when '>'
          case next_char
          when '='
            next_char_and_symbol ">="
          when '>'
            next_char_and_symbol ">>"
          else
            symbol ">"
          end
        when '&'
          next_char_and_symbol "&"
        when '|'
          next_char_and_symbol "|"
        when '^'
          next_char_and_symbol "^"
        when '~'
          next_char_and_symbol "~"
        when '%'
          next_char_and_symbol "%"
        when '['
          if next_char == ']'
            case next_char
            when '='
              symbol "[]="
            when '?'
              symbol "[]?"
            else
              symbol "[]"
            end
          else
            unknown_token
          end
        when '"'
          line = @line_number
          column = @column_number
          start = current_pos + 1
          count = 0

          while true
            char = next_char
            case char
            when '"'
              break
            when '\0'
              raise "unterminated quoted symbol", line, column
            else
              count += 1
            end
          end

          @token.type = :SYMBOL
          @token.value = string_range(start)

          next_char
        else
          if ident_start?(char)
            start = current_pos
            while ident_part?(next_char)
              # Nothing to do
            end
            if current_char == '!' || current_char == '?'
              next_char
            end
            @token.type = :SYMBOL
            @token.value = string_range(start)
          else
            @token.type = :":"
          end
        end
      when '~'
        next_char :"~"
      when '.'
        case next_char
        when '.'
          case next_char
          when '.'
            next_char :"..."
          else
            @token.type = :".."
          end
        else
          @token.type = :"."
        end
      when '&'
        case next_char
        when '&'
          case next_char
          when '='
            next_char :"&&="
          else
            @token.type = :"&&"
          end
        when '='
          next_char :"&="
        else
          @token.type = :"&"
        end
      when '|'
        case next_char
        when '|'
          case next_char
          when '='
            next_char :"||="
          else
            @token.type = :"||"
          end
        when '='
          next_char :"|="
        else
          @token.type = :"|"
        end
      when '^'
        case next_char
        when '='
          next_char :"^="
        else
          @token.type = :"^"
        end
      when '\''
        line = @line_number
        column = @column_number
        @token.type = :CHAR
        case char1 = next_char
        when '\\'
          case char2 = next_char
          when 'b'
            @token.value = '\b'
          when 'e'
            @token.value = '\e'
          when 'f'
            @token.value = '\f'
          when 'n'
            @token.value = '\n'
          when 'r'
            @token.value = '\r'
          when 't'
            @token.value = '\t'
          when 'v'
            @token.value = '\v'
          when 'u'
            value = consume_char_unicode_escape
            @token.value = value.chr
          when '0', '1', '2', '3', '4', '5', '6', '7', '8'
            char_value = consume_octal_escape(char2)
            @token.value = char_value.chr
          else
            @token.value = char2
          end
        else
          @token.value = char1
        end
        if next_char != '\''
          raise "unterminated char literal", line, column
        end
        next_char
      when '"', '`'
        delimiter = current_char
        next_char
        @token.type = :DELIMITER_START
        @token.delimiter_state = Token::DelimiterState.new(delimiter == '`' ? :command : :string, delimiter, delimiter, 0)
      when '0'
        scan_zero_number(start)
      when '1', '2', '3', '4', '5', '6', '7', '8', '9'
        scan_number current_pos
      when '@'
        start = current_pos
        case next_char
        when '['
          next_char :"@["
        else
          class_var = false
          if current_char == '@'
            class_var = true
            next_char
          end
          if ident_start?(current_char)
            while ident_part?(next_char)
              # Nothing to do
            end
            @token.type = class_var ? :CLASS_VAR : :INSTANCE_VAR
            @token.value = string_range(start)
          else
            unknown_token
          end
        end
      when '$'
        start = current_pos
        next_char
        case current_char
        when '~'
          next_char
          @token.type = :"$~"
        when '?'
          next_char
          @token.type = :"$?"
        when .digit?
          number = current_char - '0'
          while (char = next_char).digit?
            number *= 10
            number += char - '0'
          end
          @token.type = :GLOBAL_MATCH_DATA_INDEX
          @token.value = number
        else
          if ident_start?(current_char)
            while ident_part?(next_char)
              # Nothing to do
            end
          @token.type = :GLOBAL
          @token.value = string_range(start)
          else
            unknown_token
          end
        end
      when 'a'
        case next_char
        when 'b'
          if next_char == 's' && next_char == 't' && next_char == 'r' && next_char == 'a' && next_char == 'c' && next_char == 't'
            return check_ident_or_keyword(:abstract, start)
          end
        when 'l'
          if next_char == 'i' && next_char == 'a' && next_char == 's'
            return check_ident_or_keyword(:alias, start)
          end
        when 's'
          return check_ident_or_keyword(:as, start)
        end
        scan_ident(start)
      when 'b'
        case next_char
        when 'e'
          if next_char == 'g' && next_char == 'i' && next_char == 'n'
            return check_ident_or_keyword(:begin, start)
          end
        when 'r'
          if next_char == 'e' && next_char == 'a' && next_char == 'k'
            return check_ident_or_keyword(:break, start)
          end
        end
        scan_ident(start)
      when 'c'
        case next_char
        when 'a'
          if next_char == 's' && next_char == 'e'
            return check_ident_or_keyword(:case, start)
          end
        when 'l'
          if next_char == 'a' && next_char == 's' && next_char == 's'
            return check_ident_or_keyword(:class, start)
          end
        end
        scan_ident(start)
      when 'd'
        case next_char
        when 'e'
          if next_char == 'f'
            return check_ident_or_keyword(:def, start)
          end
        when 'o' then return check_ident_or_keyword(:do, start)
        end
        scan_ident(start)
      when 'e'
        case next_char
        when 'l'
          case next_char
          when 's'
            case next_char
            when 'e' then return check_ident_or_keyword(:else, start)
            when 'i'
              if next_char == 'f'
                return check_ident_or_keyword(:elsif, start)
              end
            end
          end
        when 'n'
          case next_char
          when 'd'
            return check_ident_or_keyword(:end, start)
          when 's'
            if next_char == 'u' && next_char == 'r' && next_char == 'e'
              return check_ident_or_keyword(:ensure, start)
            end
          when 'u'
            if next_char == 'm'
              return check_ident_or_keyword(:enum, start)
            end
          end
        when 'x'
          if next_char == 't' && next_char == 'e' && next_char == 'n' && next_char == 'd'
            return check_ident_or_keyword(:extend, start)
          end
        end
        scan_ident(start)
      when 'f'
        case next_char
        when 'a'
          if next_char == 'l' && next_char == 's' && next_char == 'e'
            return check_ident_or_keyword(:false, start)
          end
        when 'o'
          if next_char == 'r'
            return check_ident_or_keyword(:for, start)
          end
        when 'u'
          if next_char == 'n'
            return check_ident_or_keyword(:fun, start)
          end
        end
        scan_ident(start)
      when 'i'
        case next_char
        when 'f'
          if peek_next_char == 'd'
            next_char
            if next_char == 'e' && next_char == 'f'
              return check_ident_or_keyword(:ifdef, start)
            end
          else
            return check_ident_or_keyword(:if, start)
          end
        when 'n'
          if ident_part_or_end?(peek_next_char)
            case next_char
            when 'c'
              if next_char == 'l' && next_char == 'u' && next_char == 'd' && next_char == 'e'
                return check_ident_or_keyword(:include, start)
              end
            when 's'
              if next_char == 't' && next_char == 'a' && next_char == 'n' && next_char == 'c' && next_char == 'e' && next_char == '_' && next_char == 's' && next_char == 'i' && next_char == 'z' && next_char == 'e' && next_char == 'o' && next_char == 'f'
                return check_ident_or_keyword(:instance_sizeof, start)
              end
            end
          else
            next_char
            @token.type = :IDENT
            @token.value = :in
            return @token
          end
        when 's'
          if next_char == '_' && next_char == 'a' && next_char == '?'
            return check_ident_or_keyword(:is_a?, start)
          end
        end
        scan_ident(start)
      when 'l'
        case next_char
        when 'i'
          if next_char == 'b'
            return check_ident_or_keyword(:lib, start)
          end
        end
        scan_ident(start)
      when 'm'
        case next_char
        when 'a'
          if next_char == 'c' && next_char == 'r' && next_char == 'o'
            return check_ident_or_keyword(:macro, start)
          end
        when 'o'
          case next_char
          when 'd'
            if next_char == 'u' && next_char == 'l' && next_char == 'e'
              return check_ident_or_keyword(:module, start)
            end
          end
        end
        scan_ident(start)
      when 'n'
        case next_char
        when 'e'
          if next_char == 'x' && next_char == 't'
            return check_ident_or_keyword(:next, start)
          end
        when 'i'
          case next_char
          when 'l' then return check_ident_or_keyword(:nil, start)
          end
        end
        scan_ident(start)
      when 'o'
        case next_char
        when 'f'
            return check_ident_or_keyword(:of, start)
        when 'u'
          if next_char == 't'
            return check_ident_or_keyword(:out, start)
          end
        end
        scan_ident(start)
      when 'p'
        case next_char
        when 'o'
          if next_char == 'i' && next_char == 'n' && next_char == 't' && next_char == 'e' && next_char == 'r' && next_char == 'o' && next_char == 'f'
            return check_ident_or_keyword(:pointerof, start)
          end
        when 'r'
          case next_char
          when 'i'
            if next_char == 'v' && next_char == 'a' && next_char == 't' && next_char == 'e'
              return check_ident_or_keyword(:private, start)
            end
          when 'o'
            if next_char == 't' && next_char == 'e' && next_char == 'c' && next_char == 't' && next_char == 'e' && next_char == 'd'
              return check_ident_or_keyword(:protected, start)
            end
          end
        end
        scan_ident(start)
      when 'r'
        case next_char
        when 'e'
          case next_char
          when 's'
            if next_char == 'c' && next_char == 'u' && next_char == 'e'
              return check_ident_or_keyword(:rescue, start)
            end
          when 't'
            if next_char == 'u' && next_char == 'r' && next_char == 'n'
              return check_ident_or_keyword(:return, start)
            end
          when 'q'
            if next_char == 'u' && next_char == 'i' && next_char == 'r' && next_char == 'e'
              return check_ident_or_keyword(:require, start)
            end
          end
        end
        scan_ident(start)
      when 's'
        case next_char
        when 'e'
          if next_char == 'l' && next_char == 'f'
            return check_ident_or_keyword(:self, start)
          end
        when 'i'
          if next_char == 'z' && next_char == 'e' && next_char == 'o' && next_char == 'f'
            return check_ident_or_keyword(:sizeof, start)
          end
        when 't'
          if next_char == 'r' && next_char == 'u' && next_char == 'c' && next_char == 't'
            return check_ident_or_keyword(:struct, start)
          end
        when 'u'
          if next_char == 'p' && next_char == 'e' && next_char == 'r'
            return check_ident_or_keyword(:super, start)
          end
        end
        scan_ident(start)
      when 't'
        case next_char
        when 'h'
          if next_char == 'e' && next_char == 'n'
            return check_ident_or_keyword(:then, start)
          end
        when 'r'
          if next_char == 'u' && next_char == 'e'
            return check_ident_or_keyword(:true, start)
          end
        when 'y'
          if next_char == 'p' && next_char == 'e'
            if peek_next_char == 'o'
              next_char
              if next_char == 'f'
                return check_ident_or_keyword(:typeof, start)
              end
            else
              return check_ident_or_keyword(:type, start)
            end
          end
        end
        scan_ident(start)
      when 'u'
        if next_char == 'n'
          case next_char
          when 'd'
            if next_char == 'e' && next_char == 'f'
              return check_ident_or_keyword(:undef, start)
            end
          when 'i'
            if next_char == 'o' && next_char == 'n'
              return check_ident_or_keyword(:union, start)
            end
          when 'l'
            if next_char == 'e' && next_char == 's' && next_char == 's'
              return check_ident_or_keyword(:unless, start)
            end
          when 't'
            if next_char == 'i' && next_char == 'l'
              return check_ident_or_keyword(:until, start)
            end
          end
        end
        scan_ident(start)
      when 'w'
        case next_char
        when 'h'
          case next_char
          when 'e'
            if next_char == 'n'
              return check_ident_or_keyword(:when, start)
            end
          when 'i'
            if next_char == 'l' && next_char == 'e'
              return check_ident_or_keyword(:while, start)
            end
          end
        when 'i'
          if next_char == 't' && next_char == 'h'
            return check_ident_or_keyword(:with, start)
          end
        end
        scan_ident(start)
      when 'y'
        if next_char == 'i' && next_char == 'e' && next_char == 'l' && next_char == 'd'
          return check_ident_or_keyword(:yield, start)
        end
        scan_ident(start)
      when '_'
        case next_char
        when '_'
          case next_char
          when 'D'
            if next_char == 'I' && next_char == 'R' next_char == '_' && next_char == '_'
              if ident_part_or_end?(peek_next_char)
                scan_ident(start)
              else
                next_char
                @token.type = :__DIR__
                return @token
              end
            end
          when 'F'
            if next_char == 'I' && next_char == 'L' && next_char == 'E' && next_char == '_' && next_char == '_'
              if ident_part_or_end?(peek_next_char)
                scan_ident(start)
              else
                next_char
                @token.type = :__FILE__
                return @token
              end
            end
          when 'L'
            if next_char == 'I' && next_char == 'N' && next_char == 'E' && next_char == '_' && next_char == '_'
              if ident_part_or_end?(peek_next_char)
                scan_ident(start)
              else
                next_char
                @token.type = :__LINE__
                return @token
              end
            end
          end
        else
          unless ident_part?(current_char)
            @token.type = :UNDERSCORE
            return @token
          end
        end

        scan_ident(start)
      else
        if 'A' <= current_char <= 'Z'
          start = current_pos
          while ident_part?(next_char)
            # Nothing to do
          end
          @token.type = :CONST
          @token.value = string_range(start)
        elsif ('a' <= current_char <= 'z') || current_char == '_' || current_char.ord > 0x9F
          next_char
          scan_ident(start)
        else
          unknown_token
        end
      end

      if reset_regex_flags
        @wants_regex = true
        @slash_is_regex = false
      end

      @token
    end

    def slash_is_regex!
      @slash_is_regex = true
    end

    def slash_is_not_regex!
      @slash_is_regex = false
    end

    def consume_comment(start_pos)
      skip_comment
      @token.type = :COMMENT
      @token.value = string_range(start_pos)
      @token
    end

    def consume_doc
      char = current_char
      start_pos = current_pos

      # Ignore first whitespace after comment, like in `# some doc`
      if char == ' '
        char = next_char
        start_pos = current_pos
      end

      while char != '\n' && char != '\0'
        char = next_char_no_column_increment
      end

      if doc_buffer = @token.doc_buffer
        doc_buffer << '\n'
      else
        @token.doc_buffer = doc_buffer = StringIO.new
      end

      doc_buffer.write slice_range(start_pos)
    end

    def skip_comment
      char = current_char
      while char != '\n' && char != '\0'
        char = next_char_no_column_increment
      end
    end

    def consume_whitespace
      start_pos = current_pos
      @token.type = :SPACE
      next_char
      while true
        case current_char
        when ' ', '\t'
          next_char
        when '\\'
          if next_char == '\n'
            next_char
            @line_number += 1
            @column_number = 1
            @token.passed_backslash_newline = true
          else
            unknown_token
          end
        else
          break
        end
      end
      if @count_whitespace
        @token.value = string_range(start_pos)
      end
    end

    def consume_newlines
      while true
        case current_char
        when '\n'
          next_char_no_column_increment
          @line_number += 1
          @token.doc_buffer = nil
        when '\r'
          if next_char_no_column_increment != '\n'
            raise "expected '\\n' after '\\r'"
          end
          @line_number += 1
          @token.doc_buffer = nil
        else
          break
        end
      end
    end

    def check_ident_or_keyword(symbol, start)
      if ident_part_or_end?(peek_next_char)
        scan_ident(start)
      else
        next_char
        @token.type = :IDENT
        @token.value = symbol
      end
      @token
    end

    def scan_ident(start)
      while ident_part?(current_char)
        next_char
      end
      case current_char
      when '!', '?'
        next_char
      end
      @token.type = :IDENT
      @token.value = string_range(start)
      @token
    end

    def next_char_and_symbol(value)
      next_char
      symbol value
    end

    def symbol(value)
      @token.type = :SYMBOL
      @token.value = value
    end

    def scan_number(start, negative = false)
      @token.type = :NUMBER

      has_underscore = false
      is_integer = true
      has_suffix = true
      suffix_length = 0

      while true
        char = next_char
        if char.digit?
          # Nothing to do
        elsif char == '_'
          has_underscore = true
        else
          break
        end
      end

      case current_char
      when '.'
        is_integer = false

        if peek_next_char.digit?
          while true
            char = next_char
            if char.digit?
              # Nothing to do
            elsif char == '_'
              has_underscore = true
            else
              break
            end
          end

          if current_char == 'e' || current_char == 'E'
            next_char

            if current_char == '+' || current_char == '-'
              next_char
            end

            while true
              if current_char.digit?
                # Nothing to do
              elsif current_char == '_'
                has_underscore = true
              else
                break
              end
              next_char
            end
          end

          if current_char == 'f' || current_char == 'F'
            suffix_length = consume_float_suffix
          else
            @token.number_kind = :f64
          end
        else
          @token.number_kind = :i32
        end
      when 'e', 'E'
        is_integer = false
        next_char

        if current_char == '+' || current_char == '-'
          next_char
        end

        while true
          if current_char.digit?
            # Nothing to do
          elsif current_char == '_'
            has_underscore = true
          else
            break
          end
          next_char
        end

        if current_char == 'f' || current_char == 'F'
          suffix_length = consume_float_suffix
        else
          @token.number_kind = :f64
        end
      when 'f', 'F'
        is_integer = false
        suffix_length = consume_float_suffix
      when 'i'
        suffix_length = consume_int_suffix
      when 'u'
        suffix_length = consume_uint_suffix
      else
        has_suffix = false
        @token.number_kind = :i32
      end

      end_pos = current_pos - suffix_length

      string_value = string_range(start, end_pos)
      string_value = string_value.delete('_') if has_underscore

      if is_integer
        num_length = string_value.length
        num_length -= 1 if negative

        if has_suffix
          check_integer_literal_fits_in_size string_value, num_length, negative, start
        else
          deduce_integer_kind string_value, num_length, negative, start
        end
      end

      @token.value = string_value
    end

    macro gen_check_int_fits_in_size(type, method, length)
      if num_length >= {{length}}
        int_value = absolute_integer_value(string_value, negative)
        max = {{type}}::MAX.{{method}}
        max += 1 if negative

        if int_value > max
          raise "#{string_value} doesn't fit in an {{type}}", @token, (current_pos - start)
        end
      end
    end

    macro gen_check_uint_fits_in_size(type, length)
      if negative
        raise "Invalid negative value #{string_value} for {{type}}"
      end

      if num_length >= {{length}}
        int_value = absolute_integer_value(string_value, negative)
        if int_value > {{type}}::MAX
          raise "#{string_value} doesn't fit in an {{type}}", @token, (current_pos - start)
        end
      end
    end

    def check_integer_literal_fits_in_size(string_value, num_length, negative, start)
      case @token.number_kind
      when :i8
        gen_check_int_fits_in_size Int8, to_u8, 3
      when :u8
        gen_check_uint_fits_in_size UInt8, 3
      when :i16
        gen_check_int_fits_in_size Int16, to_u16, 5
      when :u16
        gen_check_uint_fits_in_size UInt16, 5
      when :i32
        gen_check_int_fits_in_size Int32, to_u32, 10
      when :u32
        gen_check_uint_fits_in_size UInt32, 10
      when :i64
        gen_check_int_fits_in_size Int64, to_u64, 19
      when :u64
        if negative
          raise "Invalid negative value #{string_value} for UInt64"
        end

        check_value_fits_in_uint64 string_value, num_length, start
      end
    end

    def deduce_integer_kind(string_value, num_length, negative, start)
      check_value_fits_in_uint64 string_value, num_length, start

      if num_length >= 10
        int_value = absolute_integer_value(string_value, negative)

        int64max = Int64::MAX.to_u64
        int64max += 1 if negative

        int32max = Int32::MAX.to_u32
        int32max += 1 if negative

        if int_value > int64max
          @token.number_kind = :u64
        elsif int_value > int32max
          @token.number_kind = :i64
        end
      end
    end

    def absolute_integer_value(string_value, negative)
      if negative
        string_value[1 .. -1].to_u64
      else
        string_value.to_u64
      end
    end

    def check_value_fits_in_uint64(string_value, num_length, start)
      if num_length > 20
        raise_value_doesnt_fit_in_uint64 string_value, start
      end

      if num_length == 20
        i = 0
        "18446744073709551615".each_byte do |byte|
          string_byte = string_value.byte_at(i)
          if string_byte > byte
            raise_value_doesnt_fit_in_uint64 string_value, start
          elsif string_byte < byte
            break
          end
          i += 1
        end
      end
    end

    def raise_value_doesnt_fit_in_uint64(string_value, start)
      raise "#{string_value} doesn't fit in an UInt64", @token, (current_pos - start)
    end

    def scan_zero_number(start, negative = false)
      case peek_next_char
      when 'x'
        scan_hex_number(start, negative)
      when 'b'
        scan_bin_number(start, negative)
      when '.'
        scan_number(start)
      when 'i'
        @token.type = :NUMBER
        @token.value = "0"
        next_char
        consume_int_suffix
      when 'f'
        @token.type = :NUMBER
        @token.value = "0"
        next_char
        consume_float_suffix
      when 'u'
        @token.type = :NUMBER
        @token.value = "0"
        next_char
        consume_uint_suffix
      when '_'
        case peek_next_char
        when 'i'
          @token.type = :NUMBER
          @token.value = "0"
          next_char
          consume_int_suffix
        when 'f'
          @token.type = :NUMBER
          @token.value = "0"
          next_char
          consume_float_suffix
        when 'u'
          @token.type = :NUMBER
          @token.value = "0"
          next_char
          consume_uint_suffix
        else
          scan_number(start)
        end
      else
        scan_octal_number(start, negative)
      end
    end

    def scan_bin_number(start, negative)
      next_char

      num = 0_u64
      while true
        case next_char
        when '0'
          num *= 2
        when '1'
          num = num * 2 + 1
        when '_'
          # Nothing
        else
          break
        end
      end

      finish_scan_prefixed_number num, negative, start
    end

    def scan_octal_number(start, negative)
      num = 0_u64

      while true
        char = next_char
        if '0' <= char <= '7'
          num = num * 8 + (char - '0')
        elsif char == '_'
        else
          break
        end
      end

      finish_scan_prefixed_number num, negative, start
    end

    def scan_hex_number(start, negative = false)
      next_char

      num = 0_u64
      while true
        char = next_char
        if char == '_'
        else
          hex_value = char_to_hex(char) { nil }
          if hex_value
            num = num * 16 + hex_value
          else
            break
          end
        end
      end

      finish_scan_prefixed_number num, negative, start
    end

    def finish_scan_prefixed_number(num, negative, start)
      if negative
        string_value = (-1 * num.to_i64).to_s
      else
        string_value = num.to_s
      end

      name_length = string_value.length
      name_length -= 1 if negative

      case current_char
      when 'i'
        consume_int_suffix
        check_integer_literal_fits_in_size string_value, name_length, negative, start
      when 'u'
        consume_uint_suffix
        check_integer_literal_fits_in_size string_value, name_length, negative, start
      else
        @token.number_kind = :i32
        deduce_integer_kind string_value, name_length, negative, start
      end

      @token.type = :NUMBER
      @token.value = string_value
    end

    def consume_int_suffix
      case next_char
      when '8'
        next_char
        @token.number_kind = :i8
        2
      when '1'
        if next_char == '6'
          next_char
          @token.number_kind = :i16
          3
        else
          raise "invalid int suffix"
        end
      when '3'
        if next_char == '2'
          next_char
          @token.number_kind = :i32
          3
        else
          raise "invalid int suffix"
        end
      when '6'
        if next_char == '4'
          next_char
          @token.number_kind = :i64
          3
        else
          raise "invalid int suffix"
        end
      else
        raise "invalid int suffix"
      end
    end

    def consume_uint_suffix
      case next_char
      when '8'
        next_char
        @token.number_kind = :u8
        2
      when '1'
        if next_char == '6'
          next_char
          @token.number_kind = :u16
          3
        else
          raise "invalid uint suffix"
        end
      when '3'
        if next_char == '2'
          next_char
          @token.number_kind = :u32
          3
        else
          raise "invalid uint suffix"
        end
      when '6'
        if next_char == '4'
          next_char
          @token.number_kind = :u64
          3
        else
          raise "invalid uint suffix"
        end
      else
        raise "invalid uint suffix"
      end
    end

    def consume_float_suffix
      case next_char
      when '3'
        if next_char == '2'
          next_char
          @token.number_kind = :f32
          3
        else
          raise "invalid float suffix"
        end
      when '6'
        if next_char == '4'
          next_char
          @token.number_kind = :f64
          3
        else
          raise "invalid float suffix"
        end
      else
        raise "invalid float suffix"
      end
    end

    def next_string_token(delimiter_state)
      string_end = delimiter_state.end
      string_nest = delimiter_state.nest
      string_open_count = delimiter_state.open_count

      case current_char
      when '\0'
        raise_unterminated_quoted string_end
      when string_end
        next_char
        if string_open_count == 0
          @token.type = :DELIMITER_END
        else
          @token.type = :STRING
          @token.value = string_end.to_s
          @token.delimiter_state = @token.delimiter_state.with_open_count_delta(-1)
        end
      when string_nest
        next_char
        @token.type = :STRING
        @token.value = string_nest.to_s
        @token.delimiter_state = @token.delimiter_state.with_open_count_delta(+1)
      when '\\'
        if delimiter_state.kind == :regex
          char = next_char
          next_char
          @token.type = :STRING
          @token.value = "\\#{char}"
        else
          case char = next_char
          when 'b'
            string_token_escape_value "\u{8}"
          when 'n'
            string_token_escape_value "\n"
          when 'r'
            string_token_escape_value "\r"
          when 't'
            string_token_escape_value "\t"
          when 'v'
            string_token_escape_value "\v"
          when 'f'
            string_token_escape_value "\f"
          when 'e'
            string_token_escape_value "\e"
          when 'u'
            value = consume_string_unicode_escape
            next_char
            @token.type = :STRING
            @token.value = value
          when '0', '1', '2', '3', '4', '5', '6', '7', '8'
            char_value = consume_octal_escape(char)
            next_char
            @token.type = :STRING
            @token.value = char_value.chr.to_s
          when '\n'
            @line_number += 1

            # Skip until the next non-whitespace char
            while true
              char = next_char
              case char
              when '\0'
                raise_unterminated_quoted string_end
              when '\n'
                @line_number += 1
              when .whitespace?
                # Continue
              else
                break
              end
            end
            next_string_token delimiter_state
          else
            @token.type = :STRING
            @token.value = current_char.to_s
            next_char
          end
        end
      when '#'
        if peek_next_char == '{'
          next_char
          next_char
          @token.type = :INTERPOLATION_START
        else
          next_char
          @token.type = :STRING
          @token.value = "#"
        end
      when '\n'
        next_char
        @column_number = 1
        @line_number += 1
        @token.type = :STRING
        @token.value = "\n"
      else
        start = current_pos
        count = 0
        while current_char != string_end &&
              current_char != string_nest &&
              current_char != '\0' &&
              current_char != '\\' &&
              current_char != '#' &&
              current_char != '\n'
          next_char
        end

        @token.type = :STRING
        @token.value = string_range(start)
      end

      @token
    end

    def raise_unterminated_quoted(string_end)
      msg = case string_end
            when '`' then "unterminated command"
            when '/' then "unterminated regular expression"
            else          "unterminated string literal"
            end
      raise msg, @line_number, @column_number
    end

    def next_macro_token(macro_state, skip_whitespace)
      nest = macro_state.nest
      whitespace = macro_state.whitespace
      delimiter_state = macro_state.delimiter_state
      beginning_of_line = macro_state.beginning_of_line
      yields = false

      if skip_whitespace
        while current_char.whitespace?
          whitespace = true
          if current_char == '\n'
            @line_number += 1
            @column_number = 0
            beginning_of_line = true
          end
          next_char
        end
      end

      @token.location = nil
      @token.line_number = @line_number
      @token.column_number = @column_number

      start = current_pos

      if current_char == '\0'
        @token.type = :EOF
        return @token
      end

      if !delimiter_state && current_char == '#'
        while next_char != '\n'
        end
        start = current_pos
        @token.line_number += 1
        beginning_of_line = true
        whitespace = true
      end

      if current_char == '\\' && peek_next_char == '{'
        beginning_of_line = false
        next_char
        next_char
        @token.type = :MACRO_LITERAL
        @token.value = "{"
        @token.macro_state = Token::MacroState.new(whitespace, nest, delimiter_state, beginning_of_line, yields)
        return @token
      end

      if current_char == '{'
        case next_char
        when '{'
          beginning_of_line = false
          next_char
          @token.type = :MACRO_EXPRESSION_START
          @token.macro_state = Token::MacroState.new(whitespace, nest, delimiter_state, beginning_of_line, yields)
          return @token
        when '%'
          beginning_of_line = false
          next_char
          @token.type = :MACRO_CONTROL_START
          @token.macro_state = Token::MacroState.new(whitespace, nest, delimiter_state, beginning_of_line, yields)
          return @token
        end
      end

      if !delimiter_state && current_char == 'e' && next_char == 'n'
        beginning_of_line = false
        case next_char
        when 'd'
          if whitespace && !ident_part_or_end?(peek_next_char)
            if nest == 0
              next_char
              @token.type = :MACRO_END
              @token.macro_state = Token::MacroState.default
              return @token
            else
              nest -= 1
              whitespace = current_char.whitespace?
              next_char
            end
          end
        when 'u'
          if !delimiter_state && whitespace && next_char == 'm' && !ident_part_or_end?(next_char)
            char = current_char
            nest += 1
            whitespace = true
          end
        end
      end

      char = current_char

      until char == '{' || char == '\0' || (char == '\\' && peek_next_char == '{') || (whitespace && !delimiter_state && char == 'e')
        if !delimiter_state && whitespace &&
          (
            (char == 'b' && next_char == 'e' && next_char == 'g' && next_char == 'i' && next_char == 'n') ||
            (char == 'l' && next_char == 'i' && next_char == 'b') ||
            (char == 'f' && next_char == 'u' && next_char == 'n') ||
            (beginning_of_line && char == 'i' && next_char == 'f' &&
              (char = peek_next_char) && (!ident_part_or_end?(char) ||
                char == 'd' && next_char == 'e' && next_char == 'f')) ||
            (char == 's' && next_char == 't' && next_char == 'r' && next_char == 'u' && next_char == 'c' && next_char == 't') ||
            (char == 'c' && (char = next_char) &&
              (char == 'a' && next_char == 's' && next_char == 'e') ||
              (char == 'l' && next_char == 'a' && next_char == 's' && next_char == 's')) ||
            (char == 'd' && (char = next_char) &&
              ((char == 'o') ||
               (char == 'e' && next_char == 'f'))) ||
            (char == 'm' && (char = next_char) &&
              (char == 'a' && next_char == 'c' && next_char == 'r' && next_char == 'o') ||
              (char == 'o' && next_char == 'd' && next_char == 'u' && next_char == 'l' && next_char == 'e')) ||
            (char == 'u' && next_char == 'n' && (char = next_char) &&
              (char == 'i' && next_char == 'o' && next_char == 'n') ||
              (beginning_of_line && char == 'l' && next_char == 'e' && next_char == 's' && next_char == 's') ||
              (beginning_of_line && char == 't' && next_char == 'i' && next_char == 'l')) ||
            (beginning_of_line && char == 'w' && next_char == 'h' && next_char == 'i' && next_char == 'l' && next_char == 'e')) &&
            !ident_part_or_end?(next_char)
          char = current_char
          nest += 1
          whitespace = true
          beginning_of_line = false
        elsif !delimiter_state && whitespace && char == 'y' && next_char == 'i' && next_char == 'e' && next_char == 'l' && next_char == 'd' && !ident_part_or_end?(next_char)
          yields = true
          char = current_char
          whitespace = true
          beginning_of_line = false
        else
          char = current_char
          case char
          when '\n'
            @line_number += 1
            @column_number = 0
            whitespace = true
            beginning_of_line = true
          when '\\'
            if delimiter_state
              char = next_char
              if char == '"'
                char = next_char
              end
              whitespace = false
            else
              whitespace = false
            end
          when '"'
            if delimiter_state
              delimiter_state = nil
            else
              delimiter_state = Token::DelimiterState.new(:string, '"', '"', 0)
            end
            whitespace = false
          when '%'
            if delimiter_state
              whitespace = false
            else
              case char = next_char
              when '(', '[', '<', '{'
                delimiter_state = Token::DelimiterState.new(:string, char, closing_char, 1)
              else
                whitespace = false
              end
            end
          when '#'
            if delimiter_state
              whitespace = false
            else
              break
            end
          else
            if delimiter_state
              case char
              when delimiter_state.nest
                delimiter_state = delimiter_state.with_open_count_delta(+1)
              when delimiter_state.end
                delimiter_state = delimiter_state.with_open_count_delta(-1)
                if delimiter_state.open_count == 0
                  delimiter_state = nil
                end
              end
            end

            # If an assignment comes, we accept if/unless/while/until as nesting
            if char == '=' && peek_next_char.whitespace?
              whitespace = false
              beginning_of_line = true
            else
              whitespace = char.whitespace? || char == ';' || char == '(' || char == '[' || char == '{'
              if beginning_of_line && !whitespace
                beginning_of_line = false
              end
            end
          end
          char = next_char
        end
      end

      @token.type = :MACRO_LITERAL
      @token.value = string_range(start)
      @token.macro_state = Token::MacroState.new(whitespace, nest, delimiter_state, beginning_of_line, yields)

      @token
    end

    def consume_octal_escape(char)
      char_value = char - '0'
      count = 1
      while count <= 3 && '0' <= peek_next_char <= '8'
        next_char
        char_value = char_value * 8 + (current_char - '0')
        count += 1
      end
      char_value
    end

    def consume_char_unicode_escape
      char = peek_next_char
      if char == '{'
        next_char
        consume_braced_unicode_escape
      else
        consume_non_braced_unicode_escape
      end
    end

    def consume_string_unicode_escape
      char = peek_next_char
      if char == '{'
        next_char
        consume_string_unicode_brace_escape
      else
        consume_non_braced_unicode_escape.chr.to_s
      end
    end

    def consume_string_unicode_brace_escape
      String.build do |str|
        while true
          str << consume_braced_unicode_escape(allow_spaces: true).chr
          break unless current_char == ' '
        end
      end
    end

    def consume_non_braced_unicode_escape
      codepoint = 0
      4.times do
        hex_value = char_to_hex(next_char) { expected_hexacimal_character_in_unicode_escape }
        codepoint = 16 * codepoint + hex_value
      end
      codepoint
    end

    def consume_braced_unicode_escape(allow_spaces = false)
      codepoint = 0
      found_curly = false
      found_space = false
      char = '\0'
      6.times do
        char = next_char
        case char
        when '}'
          found_curly = true
          break
        when ' '
          if allow_spaces
            found_space = true
            break
          else
            expected_hexacimal_character_in_unicode_escape
          end
        else
          hex_value = char_to_hex(char) { expected_hexacimal_character_in_unicode_escape }
          codepoint = 16 * codepoint + hex_value
        end
      end

      if codepoint == 0
        expected_hexacimal_character_in_unicode_escape
      elsif codepoint > 0x10FFFF
        raise "invalid unicode codepoint (too large)"
      end

      unless found_space
        unless found_curly
          char = next_char
        end

        unless char == '}'
          raise "expected '}' to close unicode escape"
        end
      end

      codepoint
    end


    def expected_hexacimal_character_in_unicode_escape
      raise "expected hexadecimal character in unicode escape"
    end

    def string_token_escape_value(value)
      next_char
      @token.type = :STRING
      @token.value = value
    end

    def delimited_pair(kind, string_nest, string_end)
      next_char
      @token.type = :DELIMITER_START
      @token.delimiter_state = Token::DelimiterState.new(kind, string_nest, string_end, 0)
    end

    def next_string_array_token
      while true
        if current_char == '\n'
          next_char
          @column_number = 1
          @line_number += 1
        elsif current_char.whitespace?
          next_char
        else
          break
        end
      end

      if current_char == @token.delimiter_state.end
        next_char
        @token.type = :STRING_ARRAY_END
        return @token
      end

      start = current_pos
      while !current_char.whitespace? && current_char != '\0' && current_char != @token.delimiter_state.end
        next_char
      end

      @token.type = :STRING
      @token.value = string_range(start)

      @token
    end

    def char_to_hex(char)
      if '0' <= char <= '9'
        char - '0'
      elsif 'a' <= char <= 'f'
        10 + (char - 'a')
      elsif 'A' <= char <= 'F'
        10 + (char - 'A')
      else
        yield
      end
    end

    def consume_loc_pragma
      filename_pos = current_pos

      while true
        case current_char
        when '"'
          break
        when '\0'
          raise "unexpected end of file in loc pragma"
        else
          next_char_no_column_increment
        end
      end

      filename = string_range(filename_pos)

      # skip '"'
      next_char

      unless current_char == ','
        raise "expected ',' in loc pragma after filename"
      end
      next_char

      line_number = 0
      while true
        case current_char
        when '0' .. '9'
          line_number = 10 * line_number + (current_char - '0').to_i
        when ','
          next_char
          break
        else
          raise "expected digit or ',' in loc pragma for line number"
        end
        next_char
      end

      column_number = 0
      while true
        case current_char
        when '0' .. '9'
          column_number = 10 * column_number + (current_char - '0').to_i
        when '>'
          next_char
          break
        else
          raise "expected digit or '>' in loc pragma for column_number number"
        end
        next_char
      end

      @token.filename = @filename = filename
      @token.line_number = @line_number = line_number
      @token.column_number = @column_number = column_number
    end

    def next_char_no_column_increment
      @reader.next_char
    end

    def next_char
      @column_number += 1
      next_char_no_column_increment
    end

    def next_char_check_line
      @column_number += 1
      char = next_char_no_column_increment
      if char == '\n'
        @line_number += 1
        @column_number = 1
      end
      char
    end

    def next_char(token_type)
      next_char
      @token.type = token_type
    end

    def reset_token
      @token.value = nil
      @token.line_number = @line_number
      @token.column_number = @column_number
      @token.filename = @filename
      @token.location = nil
      @token.passed_backslash_newline = false
      @token.doc_buffer = nil unless @token.type == :SPACE || @token.type == :NEWLINE
    end

    def next_token_skip_space
      next_token
      skip_space
    end

    def next_token_skip_space_or_newline
      next_token
      skip_space_or_newline
    end

    def next_token_skip_statement_end
      next_token
      skip_statement_end
    end

    def current_char
      @reader.current_char
    end

    def peek_next_char
      @reader.peek_next_char
    end

    def current_pos
      @reader.pos
    end

    def current_pos=(pos)
      @reader.pos = pos
    end

    def string
      @reader.string
    end

    def string_range(start_pos)
      string_range(start_pos, current_pos)
    end

    def string_range(start_pos, end_pos)
      @reader.string.byte_slice(start_pos, end_pos - start_pos)
    end

    def slice_range(start_pos)
      Slice.new(@reader.string.to_unsafe + start_pos, current_pos - start_pos)
    end

    def ident_start?(char)
      char.alpha? || char == '_' || char.ord > 0x9F
    end

    def ident_part?(char)
      ident_start?(char) || char.digit?
    end

    def ident_part_or_end?(char)
      ident_part?(char) || char == '?' || char == '!'
    end

    def closing_char(char = current_char)
      case char
      when '<' then '>'
      when '(' then ')'
      when '[' then ']'
      when '{' then '}'
      else          char
      end
    end

    def skip_space
      while @token.type == :SPACE
        next_token
      end
    end

    def skip_space_or_newline
      while (@token.type == :SPACE || @token.type == :NEWLINE)
        next_token
      end
    end

    def skip_statement_end
      while (@token.type == :SPACE || @token.type == :NEWLINE || @token.type == :";")
        next_token
      end
    end

    def unknown_token
      raise "unknown token: #{current_char.inspect}", @line_number, @column_number
    end

    def raise(message, line_number = @line_number, column_number = @column_number, filename = @filename)
      ::raise Crystal::SyntaxException.new(message, line_number, column_number, filename)
    end

    def raise(message, token : Token, length = nil)
      ::raise Crystal::SyntaxException.new(message, token.line_number, token.column_number, token.filename, length)
    end

    def raise(message, location : Location)
      raise message, location.line_number, location.column_number, location.filename
    end
  end
end
