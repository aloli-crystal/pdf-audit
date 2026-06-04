require "json"
require "./manifest"

module PdfAudit
  # Compare deux manifests et retourne un rapport de différences.
  # Utilisé en régression visuelle : on génère un manifest avant
  # un changement de moteur (`baseline`), un autre après, et le
  # `Differ` pointe les projets dont le rendu a évolué.
  module Differ
    extend self

    # Résultat d'une comparaison entre deux manifests.
    struct Diff
      include YAML::Serializable
      include JSON::Serializable

      property changed_sha : Bool
      property byte_delta : Int64
      property page_delta : Int32
      property word_delta : Int32
      property pages_word_delta : Array(PageWordDelta)
      property identical : Bool

      def initialize(@changed_sha, @byte_delta, @page_delta, @word_delta,
                     @pages_word_delta, @identical)
      end
    end

    struct PageWordDelta
      include YAML::Serializable
      include JSON::Serializable

      property page : Int32
      property baseline : Int32
      property after : Int32
      property delta : Int32

      def initialize(@page, @baseline, @after, @delta)
      end
    end

    def diff(baseline : Manifest, after : Manifest) : Diff
      changed_sha = baseline.sha256 != after.sha256
      byte_delta = after.byte_size - baseline.byte_size
      page_delta = after.page_count - baseline.page_count
      word_delta = after.total_words - baseline.total_words

      page_deltas = [] of PageWordDelta
      max_pages = {baseline.pages.size, after.pages.size}.max
      (0...max_pages).each do |i|
        b = baseline.pages[i]?.try(&.word_count) || 0
        a = after.pages[i]?.try(&.word_count) || 0
        next if b == a
        page_deltas << PageWordDelta.new(
          page: i + 1,
          baseline: b,
          after: a,
          delta: a - b,
        )
      end

      identical = !changed_sha && byte_delta == 0 && page_delta == 0 && word_delta == 0
      Diff.new(
        changed_sha: changed_sha,
        byte_delta: byte_delta,
        page_delta: page_delta,
        word_delta: word_delta,
        pages_word_delta: page_deltas,
        identical: identical,
      )
    end

    # Compare deux dossiers contenant chacun un manifest.yml par
    # projet. Retourne un Hash projet → Diff.
    def diff_dirs(baseline_dir : String, after_dir : String) : Hash(String, Diff)
      result = Hash(String, Diff).new
      Dir.glob(File.join(baseline_dir, "*.yml")).each do |b_path|
        name = File.basename(b_path, ".yml")
        a_path = File.join(after_dir, "#{name}.yml")
        next unless File.exists?(a_path)
        baseline = Manifest.from_yaml(File.read(b_path))
        after = Manifest.from_yaml(File.read(a_path))
        result[name] = diff(baseline, after)
      end
      result
    end
  end
end
