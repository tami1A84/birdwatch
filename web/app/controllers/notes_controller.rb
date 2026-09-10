class NotesController < ApplicationController
  MAX_TEXT = 280
  MAX_IMAGE = 10.megabytes
  # The daemon's Blossom mime map keys off the file extension, so the temp
  # file must carry one of these; content_type alone is client-claimed.
  IMAGE_TYPES = {
    "image/png" => ".png", "image/jpeg" => ".jpg",
    "image/gif" => ".gif", "image/webp" => ".webp"
  }.freeze

  # Writes ride an active NIP-46 bunker session when bunker mode is on.
  before_action :require_bunker_session!,
                only: %i[create comment like destroy]

  def show
    load_thread
    not_found! unless @note
  end

  def create
    text = params[:text].to_s.strip
    return redirect_to root_path, alert: "本文を入力してください" if text.empty? && params[:image].blank?
    return redirect_to root_path, alert: "本文は#{MAX_TEXT}文字以内にしてください" if text.length > MAX_TEXT

    note_text, tags = append_uploaded_image(text, params[:image])
    nostrd.post_note(note_text, tags: tags, client: write_client)
    redirect_to root_path, notice: "投稿しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to root_path, alert: "投稿できませんでした: #{e.message}"
  end

  def comment
    parent = find_note(params[:id])
    return not_found! unless parent

    text = params[:text].to_s.strip
    return redirect_to note_path(parent["id"]), alert: "本文を入力してください" if text.empty? && params[:image].blank?
    return redirect_to note_path(parent["id"]), alert: "本文は#{MAX_TEXT}文字以内にしてください" if text.length > MAX_TEXT

    note_text, = append_uploaded_image(text, params[:image])
    nostrd.post_comment(parent, note_text, client: write_client)
    redirect_to note_path(parent["id"]), notice: "返信しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to note_path(params[:id]), alert: "返信できませんでした: #{e.message}"
  end

  def like
    note = find_note(params[:id])
    return not_found! unless note

    nostrd.like(note["id"], note["pubkey"], client: write_client)
    redirect_to note_path(note["id"]), notice: "いいねしました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to note_path(params[:id]), alert: "いいねできませんでした: #{e.message}"
  end

  # NIP-09 delete with confirmation dialog in the UI.
  def destroy
    note = find_note(params[:id])
    return not_found! unless note

    nostrd.delete_note(note["id"], client: write_client)
    redirect_to root_path, notice: "削除しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to note_path(params[:id]), alert: "削除できませんでした: #{e.message}"
  end

  # HTML fragment for live SSE prepends.
  def item
    note = nostrd.note(params[:id])
    return head :not_found unless note

    render partial: "notes/note", locals: { note: note }
  end

  # HTML fragment refreshing the comments/reactions section on detail.
  def section
    load_thread
    return head :not_found unless @note

    render partial: "notes/thread_section"
  end

  private

  # Photo attachment: browser → temp file → daemon blob_put (the daemon
  # signs NIP-98, mirrors locally, publishes to Blossom servers) → the
  # canonical URL rides in the note content, TUI-style, plus an NIP-92
  # imeta tag so every client (not just ours) renders it as a photo.
  # The URL is appended past the 280-char text limit — image posts are
  # longer than text posts, exactly like every NIP-92 client.
  # Returns [content, tags] — comments pass the tags through (threading
  # tags are daemon-owned), notes get them signed into the kind-1 event.
  def append_uploaded_image(text, upload)
    return text, [] if upload.blank?

    mime = upload.content_type.to_s.split(";").first
    ext = IMAGE_TYPES[mime]
    raise NostrdClient::Rejected, "画像は PNG / JPEG / GIF / WebP で送ってください" unless ext
    raise NostrdClient::Rejected, "画像は10MB以内にしてください" if upload.size > MAX_IMAGE

    url = nil
    sha = nil
    Tempfile.create(["birdwatch", ext]) do |tmp|
      tmp.binmode
      tmp.write(upload.read)
      data = nostrd.blob_put(tmp.path)
      url = data.is_a?(Hash) ? data["url"].to_s : ""
      sha = data.is_a?(Hash) ? data["sha"].to_s : ""
    end
    raise NostrdClient::Rejected, "画像をアップロードできませんでした" if url.empty?

    imeta = ["imeta", "url #{url}", "m #{mime}"]
    imeta << "x #{sha}" unless sha.empty?
    attached = text.empty? ? url : "#{text}\n#{url}"
    [attached, [imeta]]
  end

  def find_note(id)
    nostrd.note(id) || (thread_data(id) || {})["note"]
  end

  def thread_data(id)
    @thread_data ||= {}
    @thread_data[id] ||= nostrd.thread(id)
  rescue NostrdClient::Error
    nil
  end

  def load_thread
    data = thread_data(params[:id])
    @note = data.is_a?(Hash) ? data["note"] : nil
    @note ||= nostrd.note(params[:id]) # older daemon: flat result
    if @note
      @comments = data.is_a?(Hash) ? Array(data["comments"]) : nostrd.cached_comments(params[:id])
      @reactions = data.is_a?(Hash) ? Array(data["reactions"]) : nostrd.cached_reactions(params[:id])
    end
  end
end
