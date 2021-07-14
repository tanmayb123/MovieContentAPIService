import MovieContentService
import Vapor
import OpenCombine

class Sessions {
    static var shared = Sessions()

    private var sessions: [String: MovieContent] = [:]
    private var semaphore = DispatchSemaphore(value: 1)

    private init() {}

    func session(with id: String) -> MovieContent? {
        semaphore.wait()
        defer { semaphore.signal() }
        return sessions[id]
    }

    func addSession(with id: String, content: MovieContent) {
        semaphore.wait()
        defer { semaphore.signal() }
        sessions[id] = content
    }
}

class SocketSearchHandler {
    private var searchService: MovieSearchService
    private var gotNewSearchResults: ([Movie]) -> ()
    private var resultsCancellable: AnyCancellable!

    struct WebSocketRequest: Codable {
        var query: String
        var nextPage: Bool
    }

    init(movieContent: MovieContent, gotNewSearchResults: @escaping ([Movie]) -> ()) {
        searchService = MovieSearchService(movieContent: movieContent)
        self.gotNewSearchResults = gotNewSearchResults
        resultsCancellable = searchService.$searchResults
            .receive(on: DispatchQueue.global(qos: .userInitiated).ocombine)
            .sink { results in
                self.gotNewSearchResults(results)
            }
    }

    func new(query: String) {
        let request = try! JSONDecoder().decode(WebSocketRequest.self, from: query.data(using: .utf8)!)
        print(request)
        if request.nextPage {
            searchService.attemptNextPage(reset: true)
        } else {
            searchService.attemptHandle(query: request.query)
        }
    }
}

func registerVaporEndpoints(application: Application) {
    func getSession(from req: Request) -> MovieContent? {
        guard let sessionId = req.query[String.self, at: "session"] else {
            return nil
        }
        guard let movieContent = Sessions.shared.session(with: sessionId) else {
            return nil
        }
        return movieContent
    }

    application.get("register") { req -> String in
        let handler: Db2Handler
        do {
            let authSettings = try req.query.decode(Db2Handler.AuthSettings.self)
            handler = try Db2Handler(authSettings: authSettings)
        } catch let error {
            return "Couldn't register. Error: \(error)"
        }
        let movieContent = MovieContent(db2Handler: handler)
        let identifier = UUID().uuidString
        Sessions.shared.addSession(with: identifier, content: movieContent)
        return identifier
    }

    application.webSocket("movie") { req, ws in
        guard let movieContent = getSession(from: req) else {
            ws.send("Invalid session ID")
            return
        }
        let handler = SocketSearchHandler(movieContent: movieContent) { results in
            guard results.count > 0 else {
                return
            }
            do {
                let resultsJSON = try JSONEncoder().encode(results)
                ws.send(String(data: resultsJSON, encoding: .utf8)!)
            } catch let error {
                ws.send("Couldn't serialize result JSON! Error: \(error)")
            }
        }
        ws.onText { ws, text in
            handler.new(query: text)
        }
    }

    application.get("genres", ":movieID") { req -> String in
        guard let movieContent = getSession(from: req) else {
            return "Invalid session ID"
        }
        guard let movieIDString = req.parameters.get("movieID") else {
            return "No movieID given"
        }
        guard let movieID = Int(movieIDString) else {
            return "Invalid movieID"
        }

        let genresString: UnsafeMutablePointer<String> = .allocate(capacity: 1)
        defer { genresString.deallocate() }
        let semaphore = DispatchSemaphore(value: 0)
        async {
            defer { semaphore.signal() }
            do {
                let movie = try await movieContent.movie(by: movieID)
                let genres = try await movieContent.genres(for: movie)
                let genresJSON = String(data: try JSONEncoder().encode(genres), encoding: .utf8)!
                genresString.pointee = genresJSON
            } catch let error {
                genresString.pointee = "Couldn't grab genres! Error: \(error)"
            }
        }
        semaphore.wait()
        return genresString.pointee
    }
}

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = Application(env)
defer { app.shutdown() }
registerVaporEndpoints(application: app)
try app.run()
