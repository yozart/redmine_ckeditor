require 'nokogiri'
require 'base64'
require 'securerandom'

namespace :redmine_ckeditor do
  namespace :embedded_images do

    desc "Extract embedded base64 images, convert to attachments, and update HTML content"
    task extract: :environment do
      puts "Starting embedded image extraction..."

      process_issues
      process_journals
      process_wiki_pages
      process_news
      process_messages

      puts " All done!"
    end

    def process_issues
      Issue.includes(:project).find_each do |issue|
        next unless issue.description&.include?("data:image")

        updated_html = extract_images_and_attach(
          record: issue,
          html: issue.description,
          container: issue,
          author: issue.author,
          field: :description
        )

        if updated_html != issue.description
          issue.update_column(:description, updated_html)
          puts " Updated Issue ##{issue.id}"
        end
      end
    end

    def process_journals
      Journal.where("notes LIKE ?", "%data:image%").find_each do |journal|
        next unless journal.notes

        updated_notes = extract_images_and_attach(
          record: journal,
          html: journal.notes,
          container: journal.journalized,
          author: journal.user,
          field: :notes
        )

        if updated_notes != journal.notes
          journal.update_column(:notes, updated_notes)
          puts " Updated Journal ##{journal.id}"
        end
      end
    end

    def process_wiki_pages
      WikiContent.joins(:page).includes(:author).where("text LIKE ?", "%data:image%").find_each do |wiki_content|
        updated_html = extract_images_and_attach(
          record: wiki_content,
          html: wiki_content.text,
          container: wiki_content.page,
          author: wiki_content.author,
          field: :text
        )

        if updated_html != wiki_content.text
          wiki_content.update_column(:text, updated_html)
          puts " Updated WikiPage ##{wiki_content.id}"
        end
      end
    end

    def process_news
      News.includes(:author).where("description LIKE ?", "%data:image%").find_each do |news|
        updated_html = extract_images_and_attach(
          record: news,
          html: news.description,
          container: news,
          author: news.author,
          field: :description
        )

        if updated_html != news.description
          news.update_column(:description, updated_html)
          puts " Updated News ##{news.id}"
        end
      end
    end

    def process_messages
      Message.includes(:author).where("content LIKE ?", "%data:image%").find_each do |message|
        updated_html = extract_images_and_attach(
          record: message,
          html: message.content,
          container: message,
          author: message.author,
          field: :content
        )

        if updated_html != message.content
          message.update_column(:content, updated_html)
          puts " Updated Message ##{message.id}"
        end
      end
    end

    def extract_images_and_attach(record:, html:, container:, author:, field:)
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      updated = false
      counter = 1

      doc.css('img').each do |img|
        next unless img['src']&.start_with?('data:image')

        if img['src'] =~ %r{^data:image/(?<format>\w+);base64,(?<data>.+)$}
          format = Regexp.last_match[:format]
          data = Base64.decode64(Regexp.last_match[:data])

          filename = "embedded_image_#{record.id}_#{counter}.#{format}"
          counter += 1

          tempfile = Tempfile.new(['embedded_image', ".#{format}"])
          tempfile.binmode
          tempfile.write(data)
          tempfile.rewind

          attachment = Attachment.create!(
            container: container,
            file: tempfile,
            author: author,
            filename: filename,
            content_type: "image/#{format}"
          )

          img['src'] = "/attachments/download/#{attachment.id}/#{filename}"
          updated = true
        end
      end

      updated ? doc.to_html : html
    end
  end
end
