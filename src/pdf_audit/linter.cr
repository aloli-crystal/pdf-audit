require "./manifest"

module PdfAudit
  # Détecte les anomalies typographiques dans un manifest de PDF.
  # Quatre règles initiales (v0.1.0) :
  #
  #   - `:margin_overflow` — un mot dépasse la marge droite
  #     attendue (`x_max > target_right`).
  #   - `:stuck_words` — deux mots sur la même ligne sont collés
  #     (gap < `min_gap_pt`, typiquement 1.0).
  #   - `:huge_gap` — deux mots sur la même ligne ont un gap
  #     anormalement grand (gap > `max_gap_pt`, typiquement 20.0),
  #     signe de justification cassée ou de tabulation détournée.
  #   - `:orphan_punctuation` — une ligne commence par une
  #     ponctuation collante (`.,;:!?»)]`), indiquant qu'elle
  #     aurait dû rester avec le mot précédent.
  module Linter
    extend self

    # Caractères « collants » qui ne devraient jamais commencer
    # une ligne : ponctuation de fin + NBSP visible.
    ORPHAN_CHARS = ".,;:!?»)]} "

    record Finding,
      kind : Symbol,
      page : Int32,
      message : String,
      x_min : Float64,
      y_min : Float64,
      x_max : Float64,
      y_max : Float64,
      text : String do
      def to_h
        {
          "kind"    => kind.to_s,
          "page"    => page,
          "message" => message,
          "bbox"    => {"x_min" => x_min, "y_min" => y_min, "x_max" => x_max, "y_max" => y_max},
          "text"    => text,
        }
      end
    end

    # Options de configuration. Tous les seuils sont en points PDF.
    record Options,
      right_margin_pt : Float64 = 36.0,
      min_gap_pt : Float64 = 0.0,
      max_gap_pt : Float64 = 20.0,
      check_overflow : Bool = true,
      check_stuck : Bool = true,
      check_huge_gap : Bool = true,
      check_orphan : Bool = true

    def lint(manifest : Manifest, opts : Options = Options.new) : Array(Finding)
      findings = [] of Finding
      manifest.pages.each do |page|
        target_right = page.width - opts.right_margin_pt

        # Grouper les mots par ligne (overlap vertical > 50 %)
        lines = group_into_lines(page.words)

        lines.each do |line_words|
          line_words.each_with_index do |w, idx|
            if opts.check_overflow && w.x_max > target_right + 0.5
              findings << Finding.new(
                kind: :margin_overflow,
                page: page.number,
                message: "Mot dépasse la marge droite (x_max=#{w.x_max.round(1)} > #{target_right.round(1)})",
                x_min: w.x_min, y_min: w.y_min, x_max: w.x_max, y_max: w.y_max,
                text: w.text,
              )
            end

            if idx == 0 && opts.check_orphan && !w.text.empty? && ORPHAN_CHARS.includes?(w.text[0])
              findings << Finding.new(
                kind: :orphan_punctuation,
                page: page.number,
                message: "Ponctuation orpheline en début de ligne : « #{w.text[0]} »",
                x_min: w.x_min, y_min: w.y_min, x_max: w.x_max, y_max: w.y_max,
                text: w.text,
              )
            end

            if idx > 0
              prev = line_words[idx - 1]
              gap = w.x_min - prev.x_max
              if opts.check_stuck && gap < opts.min_gap_pt - 0.01 && gap >= -1.0
                # gap négatif sévère = chevauchement (différent
                # de gap nul = mots collés naturellement comme
                # `code` + `)`).
                if gap < -0.5
                  findings << Finding.new(
                    kind: :stuck_words,
                    page: page.number,
                    message: "Mots chevauchants (gap=#{gap.round(2)} pt) : « #{prev.text} » + « #{w.text} »",
                    x_min: prev.x_min, y_min: prev.y_min, x_max: w.x_max, y_max: w.y_max,
                    text: "#{prev.text}|#{w.text}",
                  )
                end
              end
              if opts.check_huge_gap && gap > opts.max_gap_pt
                findings << Finding.new(
                  kind: :huge_gap,
                  page: page.number,
                  message: "Gap excessif entre 2 mots (#{gap.round(1)} pt) — justification cassée ?",
                  x_min: prev.x_max, y_min: prev.y_min, x_max: w.x_min, y_max: w.y_max,
                  text: "#{prev.text}↔#{w.text}",
                )
              end
            end
          end
        end
      end
      findings
    end

    # Groupe les mots en lignes via le critère "overlap vertical
    # > 50 %", trie par x_min croissant dans chaque ligne. Les
    # lignes sont retournées dans l'ordre y_min décroissant (= du
    # haut vers le bas de la page, convention PDF).
    private def group_into_lines(words : Array(WordEntry)) : Array(Array(WordEntry))
      return [] of Array(WordEntry) if words.empty?
      sorted = words.sort_by { |w| {-w.y_min, w.x_min} }
      lines = [] of Array(WordEntry)
      current = [sorted.first]
      sorted[1..].each do |w|
        # Same line si l'overlap vertical avec le 1er mot de la
        # ligne courante est > 50 %.
        first = current.first
        overlap = {first.y_max, w.y_max}.min - {first.y_min, w.y_min}.max
        min_h = {first.y_max - first.y_min, w.y_max - w.y_min}.min
        if min_h > 0 && overlap / min_h >= 0.5
          current << w
        else
          lines << current.sort_by(&.x_min)
          current = [w]
        end
      end
      lines << current.sort_by(&.x_min)
      lines
    end
  end
end
