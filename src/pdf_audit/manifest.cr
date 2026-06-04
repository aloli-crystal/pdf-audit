require "yaml"
require "json"
require "digest/sha256"
require "pdf2text"

module PdfAudit
  # Manifest d'un PDF : empreintes et métriques permettant de
  # détecter les changements de rendu lors d'une régénération
  # ultérieure. Sérialisable en YAML pour stockage en baseline,
  # comparable via `Differ`.
  #
  # Contient :
  #   - `path` : chemin source du PDF
  #   - `sha256` : empreinte SHA-256 du fichier
  #   - `byte_size` : taille en octets
  #   - `page_count` : nombre de pages
  #   - `pages` : array de `PageEntry` (dimensions + word count
  #     + bbox des mots)
  struct Manifest
    include YAML::Serializable
    include JSON::Serializable

    property path : String
    property sha256 : String
    property byte_size : Int64
    property page_count : Int32
    property pages : Array(PageEntry)

    def initialize(@path, @sha256, @byte_size, @page_count, @pages)
    end

    # Construit le manifest en extrayant le PDF via pdf2text.
    def self.from_pdf(path : String) : Manifest
      raw = File.read(path)
      sha = Digest::SHA256.hexdigest(raw)
      extract = ::Pdf2Text::Extractor.extract(path)
      pages = extract.pages.map { |p| PageEntry.from_pdf2text(p) }
      Manifest.new(
        path: path,
        sha256: sha,
        byte_size: File.size(path).to_i64,
        page_count: pages.size,
        pages: pages,
      )
    end

    def total_words : Int32
      pages.sum(&.word_count)
    end
  end

  struct PageEntry
    include YAML::Serializable
    include JSON::Serializable

    property number : Int32
    property width : Float64
    property height : Float64
    property word_count : Int32
    property words : Array(WordEntry)

    def initialize(@number, @width, @height, @word_count, @words)
    end

    def self.from_pdf2text(page : ::Pdf2Text::Page) : PageEntry
      words = page.words.map { |w| WordEntry.from_pdf2text(w) }
      PageEntry.new(
        number: page.number,
        width: page.width,
        height: page.height,
        word_count: words.size,
        words: words,
      )
    end
  end

  struct WordEntry
    include YAML::Serializable
    include JSON::Serializable

    property text : String
    property x_min : Float64
    property y_min : Float64
    property x_max : Float64
    property y_max : Float64
    property font_size : Float64
    property font_name : String

    def initialize(@text, @x_min, @y_min, @x_max, @y_max, @font_size, @font_name = "")
    end

    def self.from_pdf2text(w : ::Pdf2Text::Word) : WordEntry
      WordEntry.new(
        text: w.text,
        x_min: w.bbox.x_min,
        y_min: w.bbox.y_min,
        x_max: w.bbox.x_max,
        y_max: w.bbox.y_max,
        font_size: w.font_size,
        font_name: w.font_name,
      )
    end

    def width : Float64
      x_max - x_min
    end

    # Heuristique : la fonte est-elle monospace (typiquement
    # utilisée dans les blocs `[source,…]` ou inline `\`code\``) ?
    # On regarde les substrings courants dans le nom de fonte.
    def monospace? : Bool
      return false if font_name.empty?
      lower = font_name.downcase
      lower.includes?("mono") || lower.includes?("courier") || lower.includes?("typewriter")
    end
  end
end
