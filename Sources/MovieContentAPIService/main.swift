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

    init(db2Handler: Db2Handler, gotNewSearchResults: @escaping ([Movie]) -> ()) {
        let movieContent = MovieContent(db2Handler: db2Handler)
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

func registerVaporEndpoints(application: Application, db2Handler: Db2Handler) {
    application.webSocket("echo") { req, ws in
        let handler = SocketSearchHandler(db2Handler: db2Handler) { results in
            guard results.count > 0 else {
                return
            }
            let resultsJSON = try! JSONEncoder().encode(results)
            ws.send(String(data: resultsJSON, encoding: .utf8)!)
        }
        ws.onText { ws, text in
            handler.new(query: text)
        }
    }
}

let DB2_AUTH_SETTINGS = Db2Handler.AuthSettings(
    hostname: "192.168.2.22", database: "movies", dbPort: 50000, restPort: 50050,
    ssl: false, password: "filmdb2pwd", username: "db2inst1", expiryTime: "1h"
)
let db2Handler = Db2Handler(authSettings: DB2_AUTH_SETTINGS)

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = Application(env)
defer { app.shutdown() }
registerVaporEndpoints(application: app, db2Handler: db2Handler)
try app.run()
