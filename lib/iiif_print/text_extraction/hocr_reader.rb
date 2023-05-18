require 'active_support/core_ext/module/delegation'
require 'json'
require 'nokogiri'

module IiifPrint
  # Module for text extraction
  module TextExtraction
    # Class to obtain plain text and JSON word-coordinates from hOCR source
    #   - Coordinates in px units, unlike ALTO, which may have scaling concerns
    class HOCRReader
      attr_accessor :source, :doc_stream
      delegate :text, :width, :height, :words, to: :doc_stream

      # SAX Document Stream class to gather text and word tokens from hOCR
      class HOCRDocStream < Nokogiri::XML::SAX::Document
        attr_accessor :text, :words, :width, :height

        def initialize
          super()
          # plain text buffer:
          @text = ''
          # list of word hash, containing word+coord:
          @words = []
          # page width and height to be found in hOCR for `div.ocr_page`
          @width = nil
          @height = nil
          # to hold current word data state across #start_element, #characters,
          #   and #end_element methods (to associate word with coordinates).
          @current = nil
          # to preserve element classname from start to use by #end_element
          @element_class_name = nil
        end

        # Return coordinates from `span.ocrx_word` element attribute hash
        #
        # @param attrs [Hash] hash with hOCR `span.ocrx_word` element attributes
        # @return [Array] Array of position x, y, width, height in px.
        def s_coords(attrs)
          element_title = attrs['title']
          bbox = element_title.split(';')[0].split('bbox ')[-1]
          x1, y1, x2, y2 = bbox.split(' ').map(&:to_i)
          height = y2 - y1
          width = x2 - x1
          hpos = x1
          vpos = y1
          [hpos, vpos, width, height]
        end

        # Consider element for processing?
        #   - `div.ocr_page` — to get page width/height
        #   - `span.ocr_line` — to help make plain text readable
        #   - `span.ocrx_word` — for word-coordinate JSON and plain text word
        # @param name [String] Element name
        # @param class_name [String] HTML class name
        # @return [Boolean] true if element should be processed; otherwise false
        def consider?(name, class_name)
          selector = "#{name}.#{class_name}"
          ['div.ocr_page', 'span.ocr_line', 'span.ocrx_word'].include?(selector)
        end

        def start_word(attrs)
          end_word if @current  # end the current word if it exists before starting a new one
          @current = {}
          # will be replaced during #characters method call:
          @current[:word] = nil
          @current[:coordinates] = s_coords(attrs)
        end

        def start_page(attrs)
          title = attrs['title']
          fields = title.split(';')
          bbox = fields[1].split('bbox ')[-1].split(' ').map(&:to_i)
          # width and height:
          @width = bbox[2]
          @height = bbox[3]
        end

        def word_complete?
          return false if @current.nil?
          coords = @current[:coordinates]
          @current[:word] && !@current[:word].empty? && coords.size == 4
        end

        def end_word
          # add trailing space to plaintext buffer for between words:
          @text += ' ' if word_complete?
          @words.push(@current) if word_complete?
          @current = nil  # clear the current word
        end

        def end_line
          # strip trailing whitespace
          @text.strip!
          # then insert a line break
          @text += "\n"
        end

        # Callback for element start, ignores elements except for:
        #   - `div.ocr_page` — to get page width/height
        #   - `span.ocr_line` — to help make plain text readable
        #   - `span.ocrx_word` — for word-coordinate JSON and plain text word
        #
        # @param name [String] element name.
        # @param attrs [Array] Array of key, value pair Arrays.
        def start_element(name, attrs = [])
          attributes = attrs.to_h
          @element_class_name = attributes['class']
          return unless consider?(name, @element_class_name)
          start_word(attributes) if @element_class_name == 'ocrx_word'
          start_page(attributes) if @element_class_name == 'ocr_page'
        end

        def characters(value)
          return if @current.nil?
          return if @current[:coordinates].nil?
          @current[:word] ||= ''
          @current[:word] += value
          @text += value
        end

        # Callback for element end; at this time, flush word coordinate state
        #   for current word, and append line endings to plain text:
        #
        # @param name [String] element name.
        def end_element(name)
          if name == 'span'
            end_word if @element_class_name == 'ocrx_word'
            @text += "\n" if @element_class_name == 'ocr_line'
          end
          @element_class_name = nil
        end

        # Callback for completion of parsing hOCR, used to normalize generated
        #   text content (strip unneeded whitespace incidental to output and ensure
        #   a maximum of one blank line between text blocks).
        def end_document
          # Postprocess @text to remove trailing spaces on each line.
          @text = @text.split("\n").map(&:strip).join("\n")
          # Replace any instance of three or more consecutive newline characters with
          #   just two newline characters, allowing for a maximum of one blank line.
          @text.gsub!(/\n{3,}/, "\n\n")
        end
      end

      # Construct with either path or HTML [String]
      #
      # @param html [String], and process document
      def initialize(html)
        @source = isxml?(html) ? html : File.read(html)
        @doc_stream = HOCRDocStream.new
        parser = Nokogiri::HTML::SAX::Parser.new(doc_stream)
        parser.parse(@source)
      end

      # Determine if source parameter is path or xml/html
      #
      # @param xml [String] either path to xml file or xml source
      # @return [true, false] true if value appears to be XML/HTML, not path
      def isxml?(xml)
        xml.lstrip.start_with?('<')
      end

      # Output JSON flattened word coordinates
      #
      # @return [String] JSON serialization of flattened word coordinates
      def json
        words = @doc_stream.words
        IiifPrint::TextExtraction::WordCoordsBuilder.json_coordinates_for(
          words: words,
          width: @doc_stream.width,
          height: @doc_stream.height
        )
      end
    end
  end
end
