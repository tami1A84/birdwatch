require "test_helper"

# Photo attachment flow: browser upload -> temp file -> daemon blob_put ->
# URL appended to the note content. Trusted-local mode is assumed (no
# bunker): me_info {} disables the bunker gate, so writes go straight to
# the stubbed client.
class NotesControllerTest < ActionDispatch::IntegrationTest
  PNG = ["89504e470d0a1a0a0000000d4948445200000001000000010806" \
         "0000001f15c4890000000d4944415478da63fcffff3f0300" \
         "05fe02fea72d3e440000000049454e44ae426082"].pack("H*")

  setup do
    @client = Object.new
    def @client.info = {}
    def @client.connected? = true
    def @client.ready? = true
    def @client.timeline(limit: 50) = @notes || []
    def @client.profile(pk) = {}
    def @client.post_note(text, tags: [], client: nil)
      (@posts ||= []) << text
      (@note_tags ||= []) << tags
    end
    def @client.posts = @posts || []
    def @client.note_tags = @note_tags || []
    def @client.blob_put(path)
      raise "temp file vanished" unless File.file?(path)

      (@blobs ||= []) << path
      { "url" => "https://blossom.example/#{"a" * 64}",
        "sha" => "b" * 64 }
    end
    def @client.blobs = @blobs || []
    $nostrd = @client

    @png = file("shot.png")
  end

  teardown do
    $nostrd = nil
    FileUtils.rm_rf(Dir.tmpdir + "/birdwatch-test-assets") if defined?(FileUtils)
  end

  test "post with image appends the blossom url to the content" do
    post notes_path, params: { text: "look at this", image: upload(@png, "image/png") }

    assert_redirected_to root_path
    assert_equal 1, @client.posts.size
    text = @client.posts.first
    assert_equal "look at this", text.split("\n").first
    assert text.end_with?("https://blossom.example/#{"a" * 64}")
    assert_equal 1, @client.blobs.size, "temp file handed to the daemon exactly once"
  end

  test "post with image carries an NIP-92 imeta tag for other clients" do
    post notes_path, params: { text: "", image: upload(@png, "image/png") }

    assert_redirected_to root_path
    tags = @client.note_tags.first
    imeta = tags.find { |t| t.is_a?(Array) && t[0] == "imeta" }
    assert imeta, "imeta tag present"
    assert imeta.include?("url https://blossom.example/#{"a" * 64}")
    assert imeta.include?("m image/png")
    assert imeta.include?("x #{'b' * 64}"), "blob sha from the daemon rides the x token"
  end

  test "image-only post is allowed (url becomes the whole content)" do
    post notes_path, params: { text: "", image: upload(@png, "image/png") }

    assert_redirected_to root_path
    assert_match(%r{\Ahttps://blossom\.example/}, @client.posts.first)
  end

  test "non-image content types are refused without touching the daemon" do
    post notes_path, params: { text: "hi", image: upload(@png, "application/zip") }

    assert_redirected_to root_path
    assert_match "画像は PNG", flash[:alert]
    assert_empty @client.posts
    assert_empty @client.blobs
  end

  test "oversized uploads are refused" do
    big = file("big.png", "x" * (NotesController::MAX_IMAGE + 1))
    post notes_path, params: { text: "hi", image: upload(big, "image/png") }

    assert_redirected_to root_path
    assert_match "10MB以内", flash[:alert]
    assert_empty @client.posts
  end

  test "timeline renders photo urls as rounded lazy images" do
    url = "https://blossom.example/#{"a" * 64}.png"
    @client.instance_variable_set(:@notes, [
      { "id" => "n1", "pubkey" => "ab" * 32, "created_at" => Time.current.to_i,
        "kind" => 1, "content" => "snap #{url}", "tags" => [] }
    ])
    get root_path

    assert_response :success
    assert_select "img.note-image[src='#{url}']"
    assert_select "a.note-media[href='#{url}']"
    assert_select ".avatar img", minimum: 0 # no square fallbacks — clip class present
  end

  test "extensionless blossom blob urls render as photos too (TUI uploads)" do
    url = "https://blossom.example/#{"c" * 64}"
    @client.instance_variable_set(:@notes, [
      { "id" => "n2", "pubkey" => "ab" * 32, "created_at" => Time.current.to_i,
        "kind" => 1, "content" => "b-key upload #{url}", "tags" => [] }
    ])
    get root_path

    assert_select "img.note-image[src='#{url}']"
  end

  test "non-photo links of similar shape stay links" do
    @client.instance_variable_set(:@notes, [
      { "id" => "n3", "pubkey" => "ab" * 32, "created_at" => Time.current.to_i,
        "kind" => 1, "content" => "commit https://github.com/x/y/commit/deadbeef and https://a.example/short", "tags" => [] }
    ])
    get root_path

    assert_select "img.note-image", count: 0
    assert_select "a.note-url", minimum: 2
  end

  test "note_content renders NIP-92 imeta attachments absent from the text" do
    url = "https://blossom.example/#{"b" * 64}"
    html = ApplicationController.new.note_content(
      { "content" => "photo", "tags" => [["imeta", "url #{url} m image/png"]] }
    )
    assert_includes html, %(<img class="note-image" src="#{url}")
    assert_includes html, "photo"
  end

  test "relay page splits my relays from discovered gossip rows" do
    def @client.info
      { "relays" => [
        { "url" => "wss://mine.example", "state" => "connected", "mine" => true,
          "read" => true, "write" => true },
        { "url" => "wss://gossip.example", "state" => "connected", "mine" => false }
      ] }
    end

    get relays_path

    assert_response :success
    assert_select ".relay-section", 2
    assert_select ".relay-section", "my relays (NIP-65)"
    assert_select ".relay-section", "discovered (gossip)"
    assert_select "form.relay-flags", 1 # switches only on my relays
    assert_select ".relay-row--read .relay-row__url", "wss://gossip.example"
  end

  private

  def file(name, content = PNG)
    dir = Dir.mktmpdir("birdwatch-test-assets")
    path = File.join(dir, name)
    File.binwrite(path, content)
    path
  end

  def upload(path, type)
    Rack::Test::UploadedFile.new(path, type)
  end
end
