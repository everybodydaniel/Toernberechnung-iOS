import SwiftData
import SwiftUI

struct FeedCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SocialAuthViewModel.self) private var auth
    @Query(sort: \FeedComment.createdAt, order: .forward) private var comments: [FeedComment]

    let post: FeedPost
    let currentSkipperName: String

    @State private var draft = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var api: SocialFeedAPI {
        SocialFeedAPI(
            authTokenProvider: { try await auth.validIDToken() },
            skipperIDProvider: { auth.skipperID }
        )
    }

    init(post: FeedPost, currentSkipperName: String) {
        self.post = post
        self.currentSkipperName = currentSkipperName

        let postID = post.id
        _comments = Query(
            filter: #Predicate<FeedComment> { $0.postID == postID },
            sort: \FeedComment.createdAt,
            order: .forward
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(comment.skipperName)
                                .font(.system(size: 13, weight: .bold))
                            Text(comment.text)
                                .font(.system(size: 14))
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)

                VStack(spacing: 8) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }

                    HStack(spacing: 10) {
                        TextField("Kommentar", text: $draft, axis: .vertical)
                            .lineLimit(1...3)
                            .padding(10)
                            .background(
                                Color.fieldBackground,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )

                        Button {
                            Task { await sendComment() }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                        .appGlassButton(tint: Color(hex: 0x3C82FF))
                    }
                }
                .padding(12)
            }
            .navigationTitle("Kommentare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .task { await loadComments() }
    }

    @MainActor
    private func loadComments() async {
        isLoading = true
        do {
            let remote = try await api.fetchComments(postID: post.id)
            SocialFeedCache.upsert(comments: remote, in: modelContext)
        } catch {
            errorMessage = "Offline-Kommentare werden angezeigt."
        }
        isLoading = false
    }

    @MainActor
    private func sendComment() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isLoading = true
        do {
            let response = try await api.createComment(
                postID: post.id,
                skipperName: currentSkipperName,
                text: text
            )
            SocialFeedCache.upsert(comment: response.comment, in: modelContext)
            SocialFeedCache.upsert(post: response.post, in: modelContext)
            draft = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
