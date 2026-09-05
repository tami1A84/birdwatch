class NotesController < ApplicationController
  MAX_TEXT = 280

  def show
    load_thread
    not_found! unless @note
  end

  def create
    text = params.require(:text).to_s.strip
    return redirect_to root_path, alert: "本文を入力してください" if text.empty?
    return redirect_to root_path, alert: "本文は#{MAX_TEXT}文字以内にしてください" if text.length > MAX_TEXT

    nostrd.post_note(text)
    redirect_to root_path, notice: "投稿しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to root_path, alert: "投稿できませんでした: #{e.message}"
  end

  def comment
    parent = find_note(params[:id])
    return not_found! unless parent

    text = params.require(:text).to_s.strip
    return redirect_to note_path(parent["id"]), alert: "本文を入力してください" if text.empty?
    return redirect_to note_path(parent["id"]), alert: "本文は#{MAX_TEXT}文字以内にしてください" if text.length > MAX_TEXT

    nostrd.post_comment(parent, text)
    redirect_to note_path(parent["id"]), notice: "返信しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to note_path(params[:id]), alert: "返信できませんでした: #{e.message}"
  end

  def like
    note = find_note(params[:id])
    return not_found! unless note

    nostrd.like(note["id"], note["pubkey"])
    redirect_to note_path(note["id"]), notice: "いいねしました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to note_path(params[:id]), alert: "いいねできませんでした: #{e.message}"
  end

  # NIP-09 delete with confirmation dialog in the UI.
  def destroy
    note = find_note(params[:id])
    return not_found! unless note

    nostrd.delete_note(note["id"])
    redirect_to root_path, notice: "削除しました"
  rescue NostrdClient::Rejected, NostrdClient::Error => e
    redirect_to note_path(params[:id]), alert: "削除できませんでした: #{e.message}"
  end

  # HTML fragment for live SSE prepends.
  def card
    note = nostrd.note(params[:id])
    return head :not_found unless note

    render partial: "notes/card", locals: { note: note }
  end

  # HTML fragment refreshing the comments/reactions section on detail.
  def section
    load_thread
    return head :not_found unless @note

    render partial: "notes/thread_section"
  end

  private

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
