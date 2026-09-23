require "json"

module GrantParity
  VALID_STATUSES = {"complete", "partial", "missing", "n.a."}

  class Feature
    include JSON::Serializable

    property area : String
    property feature : String
    property status : String
    property evidence_spec_paths : Array(String)
    property gap : String
    property not_applicable_reason : String
    property priority : Int32?
  end

  class SourceDocument
    include JSON::Serializable

    property baseline_source_commit : String
    property verified_against_commit : String
    property baseline_counts : Hash(String, Int32)
    property features : Array(Feature)
  end

  record Counts, complete : Int32, partial : Int32, missing : Int32, not_applicable : Int32 do
    def applicable : Int32
      complete + partial + missing
    end

    def total : Int32
      applicable + not_applicable
    end

    def percent : Float64
      return 0.0 if applicable == 0
      complete.to_f64 * 100.0 / applicable
    end
  end

  record RenderedFiles, markdown : String, crystal : String

  module Generator
    extend self

    def counts(document : SourceDocument) : Counts
      Counts.new(
        document.features.count { |feature| feature.status == "complete" }.to_i32,
        document.features.count { |feature| feature.status == "partial" }.to_i32,
        document.features.count { |feature| feature.status == "missing" }.to_i32,
        document.features.count { |feature| feature.status == "n.a." }.to_i32
      )
    end

    def render(document : SourceDocument, version : String, root = Dir.current) : RenderedFiles
      validate!(document, root)
      summary = counts(document)
      markdown = render_markdown(document, version, summary)
      RenderedFiles.new(markdown, render_crystal(markdown, summary))
    end

    def write(document : SourceDocument, version : String, root = Dir.current, refresh_snapshot = false) : RenderedFiles
      rendered = render(document, version, root)
      markdown_path = File.join(root, "docs", "PARITY.md")
      crystal_path = File.join(root, "src", "grant", "parity.cr")
      snapshot_path = File.join(root, "docs", "parity", "#{version}.md")

      snapshot_exists = File.file?(snapshot_path)
      if snapshot_exists && File.read(snapshot_path) != rendered.markdown && !refresh_snapshot
        raise "Refusing to replace immutable parity snapshot #{snapshot_path}; bump Grant::VERSION for a new snapshot."
      end

      File.write(markdown_path, rendered.markdown)
      File.write(crystal_path, rendered.crystal)
      File.write(snapshot_path, rendered.markdown) if refresh_snapshot || !snapshot_exists
      rendered
    end

    private def validate!(document : SourceDocument, root : String)
      raise "Parity source has no features" if document.features.empty?
      unless document.verified_against_commit.matches?(/\A[0-9a-f]{7,40}\z/)
        raise "verified_against_commit must be a Git commit hash"
      end

      keys = {} of String => Nil
      document.features.each do |feature|
        validate_feature!(feature, root, keys)
      end
    end

    private def validate_feature!(feature : Feature, root : String, keys : Hash(String, Nil))
      raise "Unknown status #{feature.status.inspect} for #{feature.feature}" unless VALID_STATUSES.includes?(feature.status)
      raise "Feature area and name cannot be blank" if feature.area.strip.empty? || feature.feature.strip.empty?

      key = "#{feature.area}\u0000#{feature.feature}"
      raise "Duplicate parity feature #{feature.area}: #{feature.feature}" if keys.has_key?(key)
      keys[key] = nil

      validate_complete_evidence!(feature, root) if feature.status == "complete"
      validate_na_reason!(feature) if feature.status == "n.a."
      if feature.status == "missing" && feature.priority.nil?
        raise "Missing feature requires an explicit priority: #{feature.feature}"
      end
    end

    private def validate_complete_evidence!(feature : Feature, root : String)
      raise "Complete feature requires a named spec: #{feature.feature}" if feature.evidence_spec_paths.empty?
      feature.evidence_spec_paths.each do |path|
        full_path = File.join(root, path)
        raise "Complete feature spec does not exist: #{path}" unless File.file?(full_path)
      end
    end

    private def validate_na_reason!(feature : Feature)
      if feature.not_applicable_reason.strip.empty? || feature.not_applicable_reason.includes?('\n')
        raise "N/A feature requires a one-line reason: #{feature.feature}"
      end
    end

    private def render_markdown(document : SourceDocument, version : String, summary : Counts) : String
      lines = [] of String
      lines << "# Grant / ActiveRecord 8 parity"
      lines << ""
      lines << "- Grant version: `#{version}`"
      lines << "- Generated for commit: `#{document.verified_against_commit}`"
      lines << "Baseline score source: commit `#{document.baseline_source_commit}`."
      lines << ""
      lines << "## Headline"
      lines << ""
      lines << "**#{summary.complete} complete / #{summary.partial} partial / #{summary.missing} missing / #{summary.not_applicable} not applicable**"
      lines << ""
      lines << "#{format_percent(summary.percent)}% of applicable features complete (#{summary.complete} / #{summary.applicable}); #{summary.total} features tracked."
      lines << ""
      lines << "## Counts by area"
      lines << ""
      lines << "| Area | Complete | Partial | Missing | N/A | Applicable |"
      lines << "| --- | ---: | ---: | ---: | ---: | ---: |"
      grouped_features(document).each do |area, features|
        counts = count_features(features)
        lines << "| #{escape_cell(area)} | #{counts.complete} | #{counts.partial} | #{counts.missing} | #{counts.not_applicable} | #{counts.applicable} |"
      end
      lines << "| **Total** | **#{summary.complete}** | **#{summary.partial}** | **#{summary.missing}** | **#{summary.not_applicable}** | **#{summary.applicable}** |"
      lines << ""
      lines << "## Feature status by area"
      lines << ""
      grouped_features(document).each do |area, features|
        lines << "### #{area}"
        lines << ""
        lines << "| Feature | Status | Evidence specs | Gap or N/A reason |"
        lines << "| --- | --- | --- | --- |"
        features.each do |feature|
          evidence = feature.evidence_spec_paths.map { |path| "`#{escape_cell(path)}`" }.join(", ")
          explanation = feature.status == "n.a." ? feature.not_applicable_reason : feature.gap
          explanation = "—" if explanation.empty?
          lines << "| #{escape_cell(feature.feature)} | #{feature.status} | #{evidence} | #{escape_cell(explanation)} |"
        end
        lines << ""
      end
      lines << "## Prioritized missing features"
      lines << ""
      missing_features = document.features.select { |feature| feature.status == "missing" }
      missing_features.sort_by! { |feature| {feature.priority || Int32::MAX, feature.area, feature.feature} }
      missing_features.each do |feature|
        lines << "#{feature.priority}. **#{feature.feature}** (#{feature.area}) — #{feature.gap}"
      end
      lines << ""
      lines.join("\n")
    end

    private def render_crystal(markdown : String, summary : Counts) : String
      doc_lines = [
        "# Generated by scripts/generate_parity.cr from docs/parity/parity.json.",
        "# This module is documentation-only; use these constants to read the score.",
        "#",
      ] + markdown.lines.map do |line|
        text = line.strip
        text.empty? ? "#" : "# #{text}"
      end

      constants = [
        {"COMPLETE", summary.complete.to_s},
        {"PARTIAL", summary.partial.to_s},
        {"MISSING", summary.missing.to_s},
        {"NOT_APPLICABLE", summary.not_applicable.to_s},
        {"APPLICABLE", summary.applicable.to_s},
        {"TOTAL", summary.total.to_s},
        {"PERCENT", "#{format_percent(summary.percent)}_f64"},
      ]
      name_width = constants.max_of(&.[0].size)
      value_width = constants.max_of(&.[1].size)
      constant_lines = constants.map do |(name, value)|
        "  #{name}#{" " * (name_width - name.size)} = #{" " * (value_width - value.size)}#{value}"
      end

      (doc_lines + [
        "module Grant::Parity",
      ] + constant_lines + ["end", ""]).join("\n")
    end

    private def grouped_features(document : SourceDocument) : Array(Tuple(String, Array(Feature)))
      document.features.group_by(&.area).to_a.sort_by(&.[0])
    end

    private def count_features(features : Array(Feature)) : Counts
      Counts.new(
        features.count { |feature| feature.status == "complete" }.to_i32,
        features.count { |feature| feature.status == "partial" }.to_i32,
        features.count { |feature| feature.status == "missing" }.to_i32,
        features.count { |feature| feature.status == "n.a." }.to_i32
      )
    end

    private def format_percent(percent : Float64) : String
      sprintf("%.1f", percent)
    end

    private def escape_cell(value : String) : String
      value.gsub("|", "\\|").gsub("\n", " ").gsub("\r", " ")
    end
  end
end
