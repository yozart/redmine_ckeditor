require 'nokogiri'
require 'cgi'

namespace :redmine_ckeditor do
  namespace :assets do
    desc "copy assets"
    task :copy => :environment do
      env = Sprockets::Environment.new(RedmineCkeditor.root)
      Rails.application.config.assets.paths.each do |path|
        env.append_path(path)
      end
      env.append_path("app/assets/javascripts")
      %w(application.js browser.js).each do |asset|
        assets = env.find_asset(asset)
        assets.write_to(RedmineCkeditor.root.join("assets/javascripts", asset))
      end

      ckeditor = RedmineCkeditor.root.join("assets/ckeditor")
      rm_rf ckeditor
      cp_r RedmineCkeditor.root.join("app/assets/javascripts/ckeditor-releases"), ckeditor
      rm ckeditor.join(".git")
    end
  end

  class Migration
    FORMATS = %w[textile markdown html]

    def initialize(projects, from, to)
      @from = from
      @to = to
      @projects = projects
    end

    def start
      [@from, @to].each do |format|
        next if FORMATS.include?(format)
        puts "#{format} format is not supported."
        puts "Available formats: #{FORMATS.join(", ")}"
        return
      end

      messages = [
        "*** WARNING ***",
        "It is strongly recommended to backup your database before migration, because it cannot be rolled back completely.",
        "***************"
      ]

      if @projects.empty?
        @projects = Project.all
        messages << "projects: ALL"
      else
        messages << "projects: #{@projects.pluck(:identifier).join(",")}"
      end
      messages << "migration: #{@from} to #{@to}"

      messages.each {|message| puts message}
      print "Do you want to continue? (type 'y' to continue): "
      unless STDIN.gets.chomp == 'y'
        puts "Cancelled"
        return
      end

      @projects.each do |project|
        ActiveRecord::Base.transaction do
          puts "project #{project.name}"
          project.update_column(:description, convert(project.description))
          migrate(:issues, project.issues, :description)
          migrate(:journals, Journal.where(journalized_type: "Issue", journalized_id: project.issues), :notes)
          migrate(:documents, project.documents, :description)
          migrate(:messages, Message.where(board_id: project.boards), :content)
          migrate(:news, project.news, :description)
          migrate(:comments, Comment.where(commented_type: "News", commented_id: project.news), :comments)
          migrate(:wiki, WikiContent.where(page_id: project.wiki.pages), :text) if project.wiki
        end
      end
    end

    def migrate(type, records, column)
      n = records.count
      return if n == 0
      records.each_with_index do |record, i|
        print "\rMigrating #{type} ... (#{i}/#{n})"
        record.update_column(column, convert(record.send(column)))
      end
      puts "\rMigrating #{type} ... done  (#{n})           "
    end

    def clean_html(html)
	  doc = Nokogiri::HTML::DocumentFragment.parse(html)
	  doc.search('colgroup, col, thead, tbody, tfoot').each do |node|
		node.replace(node.children)  # Keep inner <tr>, etc.
	  end
	  doc  # Return the fragment, not serialized HTML
	end

    def convert_tables_manually(html)
	  doc = Nokogiri::HTML::DocumentFragment.parse(html)

	  # === STEP 1: Extract <pre><code> blocks and replace with placeholders ===
	  code_blocks = {}
	  doc.css('pre > code').each_with_index do |code_node, index|
		placeholder = "%%CODEBLOCK#{index}%%"
		code_text = code_node.text
		lang = code_node['class'] || ""
		# Wrap in <notextile> to prevent Textile parser from altering code
		wrapped = "<notextile><pre><code class=\"#{lang}\">\n#{CGI.escapeHTML(code_text)}\n</code></pre></notextile>"
		code_blocks[placeholder] = wrapped
		# Replace entire <pre> with placeholder
		code_node.parent.replace(Nokogiri::XML::Text.new(placeholder, doc))
	  end

	  # === STEP 2: Flatten <p> and <span> (clean CKEditor wrappers) ===
	  doc.css('p, span').each do |node|
		br = Nokogiri::XML::Node.new('br', doc)
		node.add_next_sibling(br)
		node.replace(node.children)
	  end

	  # === STEP 3: Flatten <thead>, <tbody>, etc. ===
	  doc.css('thead, tbody').each do |node|
		node.replace(node.children)
	  end

	  # === STEP 4: Clean tags and styles ===
	  allowed_tags = %w[table tr th td b i u br img li ul strong h1 h2 h3 object embed]
	  doc.traverse do |node|
		next unless node.element?

		# Keep only 'color' style if present
		if node['style']
		  allowed_styles = []
		  if node['style'] =~ /color\s*:\s*[^;]+/i
			allowed_styles << node['style'][/color\s*:\s*[^;]+/i]
		  end
		  if allowed_styles.any?
			node['style'] = allowed_styles.join('; ')
		  else
			node.remove_attribute('style')
		  end
		end

		# Remove tags not in the allowlist but keep their content
		unless allowed_tags.include?(node.name)
		  node.replace(node.children)
		end
	  end

	  # === STEP 5: Convert tables to Textile manually ===
	  doc.css('table').each do |table|
		textile = table.css('tr').map do |tr|
		  cells = tr.css('th, td').map do |cell|
			content = cell.inner_html

			# Convert basic formatting tags to Textile
			content.gsub!(/<b>(.*?)<\/b>/i, '*\1*')
			content.gsub!(/<strong>(.*?)<\/strong>/i, '*\1*')
			content.gsub!(/<i>(.*?)<\/i>/i, '_\1_')
			content.gsub!(/<u>(.*?)<\/u>/i, '+\1+')
			content.gsub!(/<br\s*\/?>/i, '<br>')

			# Convert image tags
			content.gsub!(/<img [^>]*src=["']([^"']+)["'][^>]*>/i, ' !\1! ')

			# Remove any remaining tags
			content.gsub!(/<\/?[^>]+>/, '')

			# Escape pipe symbol
			content.gsub!('|', '\|')
			content = content.lines.map(&:strip).reject(&:empty?).join('<br>')

			# Handle colspan
			colspan = cell['colspan']
			prefix = colspan ? "\\#{colspan}." : ""

			"#{prefix} #{content}"
		  end
		  "|#{cells.join('|')}|"
		end.join("<br>")

		table.replace(Nokogiri::XML::Text.new("<br><br>#{textile}<br><br>", doc))
	  end

	  # === STEP 6: Restore code blocks ===
			
	  textile_output = CGI.unescapeHTML(doc.to_html)
	  code_blocks.each do |placeholder, original_block|
		textile_output.gsub!(placeholder, original_block)
	  end

	  textile_output
	end




    def convert(text)
	  return unless text
	  begin
	    # Step 1: Extract code blocks and replace with placeholders
	    doc = clean_html(text)
	    code_blocks = {}
	    doc.css('pre > code').each_with_index do |code_node, index|
	      placeholder = "%%CODEBLOCK#{index}%%"
	      code_text = code_node.text
	      lang = code_node['class'] || ""
	      wrapped = "<notextile><pre><code class=\"#{lang}\">\n#{CGI.escapeHTML(code_text)}\n</code></pre></notextile>"
	      code_blocks[placeholder] = wrapped
	      code_node.parent.replace(Nokogiri::XML::Text.new(placeholder, doc))
	    end

	    # Step 2: Convert rest of HTML using manual Textile processing
	    textile_text = convert_tables_manually(doc)

	    # Step 3: Run Pandoc on cleaned-up portion (without code blocks)
	    converted = CGI.unescapeHTML(PandocRuby.convert(textile_text, from: @from, to: @to))

	    # Step 4: Restore the code block placeholders
	    code_blocks.each do |placeholder, original|
	      converted.gsub!(placeholder, original)
	    end

	    converted
	  rescue => e
	    puts "\nErreur de conversion Pandoc : #{e.message}"
	    puts "Texte original : #{text[0..200]}..."
	    text
	  end
	end


  
end
	
  desc "Migrate text to html"
  task :migrate => :environment do
    projects = Project.where(identifier: ENV['PROJECT'].to_s.split(","))
    from = ENV['FROM'] || Setting.text_formatting
    from = "html" if from == "CKEditor"
    to = ENV['TO'] || "html"
    Migration.new(projects, from, to).start
  end
end
