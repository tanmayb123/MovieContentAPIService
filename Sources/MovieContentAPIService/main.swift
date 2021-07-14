import MovieContentService
import Vapor
import OpenCombine



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

func registerVaporEndpoints(application: Application, movieContent: MovieContent) {
    application.webSocket("movie") { req, ws in
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

let DB2_AUTH_SETTINGS = Db2Handler.AuthSettings(
    hostname: "192.168.2.22", database: "movies", dbPort: 50000, restPort: 50050,
    ssl: false, password: "filmdb2pwd", username: "db2inst1", expiryTime: "1h"
)
let db2Handler = Db2Handler(authSettings: DB2_AUTH_SETTINGS)
let movieContent = MovieContent(db2Handler: db2Handler)

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = Application(env)
defer { app.shutdown() }
registerVaporEndpoints(application: app, movieContent: movieContent)
try app.run()
