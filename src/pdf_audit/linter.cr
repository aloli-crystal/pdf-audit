require "./manifest"

module PdfAudit
  # Détecte les anomalies typographiques dans un manifest de PDF.
  # Quatre règles principales :
  #
  #   - `:margin_overflow` — un mot dépasse la marge droite
  #     attendue (`x_max > target_right + tolerance_pt`).
  #   - `:stuck_words` — deux mots sur la même ligne sont
  #     chevauchants (gap << 0).
  #   - `:huge_gap` — deux mots sur la même ligne ont un gap
  #     anormalement grand (gap > `max_gap_pt`), signe de
  #     justification cassée ou de tabulation détournée.
  #   - `:orphan_punctuation` — une ligne commence par une
  #     ponctuation collante (`.,;:!?»)]`), indiquant qu'elle
  #     aurait dû rester avec le mot précédent.
  #
  # Filtres anti-faux-positifs (v0.2.0) appliqués sur `huge_gap` :
  #
  #   - **Admonition** : si le 1er mot de la ligne est
  #     NOTE/TIP/WARNING/CAUTION/IMPORTANT, on ignore le huge_gap
  #     entre lui et le mot suivant (layout intentionnel du label
  #     d'admonition).
  #   - **Header/footer** : si le huge_gap est entre 2 mots dont
  #     le 1er est près du bord gauche (`x_min < 60`) et le 2ᵉ
  #     près du bord droit (`x_min > page_width - 100`), c'est
  #     un alignement intentionnel — typiquement « Beryl ↔ 1 ».
  #   - **Commentaire aligné en bloc code** : si le 2ᵉ mot
  #     commence par `#` ET est proche du bord droit
  #     (`x_min > page_width × 0.4`), c'est un commentaire en bout
  #     de ligne de code, intentionnel.
  module Linter
    extend self

    # Caractères « collants » qui ne devraient jamais commencer
    # une ligne : ponctuation de fin + NBSP visible.
    ORPHAN_CHARS = ".,;:!?»)]} "

    # Labels d'admonition (asciidoctor standard + ALOLI custom)
    # qui justifient un gap intentionnel avec le texte suivant.
    ADMONITION_LABELS = {"NOTE", "TIP", "WARNING", "CAUTION", "IMPORTANT"}

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
    #
    # `right_margin_pt` : largeur attendue de la marge droite
    # (`target_right = page_width - right_margin_pt`).
    #
    # `overflow_tolerance_pt` (v0.2.0) : marge de tolérance avant
    # de reporter un `margin_overflow`. Compense l'imprécision de
    # mesure de pdf2text sur les chars dont le CID n'a pas
    # d'entrée dans `/W` (typiquement `→`, `…`, certaines
    # ponctuations finales). Défaut : 3 pt. Au-delà, on considère
    # le débordement comme un vrai bug.
    #
    # `min_gap_pt` : seuil de chevauchement (gap < 0 et < ce seuil
    # ⇒ stuck_words).
    #
    # `max_gap_pt` : seuil de gap excessif (gap > ce seuil ⇒
    # huge_gap après filtrage des faux positifs).
    record Options,
      right_margin_pt : Float64 = 36.0,
      overflow_tolerance_pt : Float64 = 3.0,
      min_gap_pt : Float64 = 0.0,
      max_gap_pt : Float64 = 20.0,
      check_overflow : Bool = true,
      check_stuck : Bool = true,
      check_huge_gap : Bool = true,
      check_orphan : Bool = true,
      check_admonition_layout : Bool = true,
      check_header_footer : Bool = true,
      check_code_comment : Bool = true

    def lint(manifest : Manifest, opts : Options = Options.new) : Array(Finding)
      findings = [] of Finding
      manifest.pages.each do |page|
        target_right = page.width - opts.right_margin_pt
        page_width = page.width

        lines = group_into_lines(page.words)

        lines.each do |line_words|
          # Pré-calcul : la ligne courante commence-t-elle par un
          # label d'admonition ? Utilisé pour filtrer le huge_gap
          # qui sépare le label du début du texte.
          first_is_admonition = opts.check_admonition_layout &&
                                !line_words.empty? &&
                                ADMONITION_LABELS.includes?(line_words.first.text.strip)

          line_words.each_with_index do |w, idx|
            if opts.check_overflow && w.x_max > target_right + opts.overflow_tolerance_pt
              findings << Finding.new(
                kind: :margin_overflow,
                page: page.number,
                message: "Mot dépasse la marge droite (x_max=#{w.x_max.round(1)} > #{target_right.round(1)} + tolerance #{opts.overflow_tolerance_pt})",
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

            next if idx == 0
            prev = line_words[idx - 1]
            gap = w.x_min - prev.x_max

            if opts.check_stuck && gap < -0.5
              findings << Finding.new(
                kind: :stuck_words,
                page: page.number,
                message: "Mots chevauchants (gap=#{gap.round(2)} pt) : « #{prev.text} » + « #{w.text} »",
                x_min: prev.x_min, y_min: prev.y_min, x_max: w.x_max, y_max: w.y_max,
                text: "#{prev.text}|#{w.text}",
              )
            end

            if opts.check_huge_gap && gap > opts.max_gap_pt
              # Filtres anti-faux-positifs avant de reporter
              # l'anomalie. Si l'un des filtres détecte un layout
              # intentionnel, on skip.
              next if first_is_admonition && idx == 1
              next if opts.check_header_footer && header_footer_layout?(prev, w, page_width)
              next if opts.check_code_comment && code_comment_layout?(prev, w, page_width)

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
      findings
    end

    # Header/footer : 2 mots dont le 1er est près du bord gauche
    # (x_min < 60) et le 2ᵉ près du bord droit (x_min > page_width
    # - 100). Typique : « Beryl ↔ 1 » dans le pied de page.
    private def header_footer_layout?(prev : WordEntry, w : WordEntry, page_width : Float64) : Bool
      prev.x_min < 60.0 && w.x_min > page_width - 100.0
    end

    # Commentaire aligné en bloc de code : le 2ᵉ mot commence par
    # `#`. Pour distinguer d'un usage prose (rare, ex. « le tag
    # #123 »), on exige ou bien une position dans la 2ᵉ moitié de
    # page (alignement à droite typique du bloc code), ou bien un
    # gap minimum de 30 pt (= bien plus qu'un simple espace
    # justifié, signe d'un alignement intentionnel).
    private def code_comment_layout?(prev : WordEntry, w : WordEntry, page_width : Float64) : Bool
      return false if w.text.empty? || w.text[0] != '#'
      gap = w.x_min - prev.x_max
      w.x_min > page_width * 0.3 || gap > 30.0
    end

    # Groupe les mots en lignes via le critère "overlap vertical
    # > 50 %", trie par x_min croissant dans chaque ligne.
    private def group_into_lines(words : Array(WordEntry)) : Array(Array(WordEntry))
      return [] of Array(WordEntry) if words.empty?
      sorted = words.sort_by { |w| {-w.y_min, w.x_min} }
      lines = [] of Array(WordEntry)
      current = [sorted.first]
      sorted[1..].each do |w|
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
