import Foundation

enum TestFixtures {

    static let bshEmdenJSON: String = """
    {
      "years": {
        "2026": {
          "MHW": 350.0,
          "MNW": 50.0,
          "hwnw_prediction": {
            "data": [
              { "timestamp": "2026-05-25 06:42:00+02:00", "height": 360.0, "type": "HW", "phase": "S" },
              { "timestamp": "2026-05-25 13:08:00+02:00", "height": 45.0,  "type": "NW", "phase": null },
              { "timestamp": "2026-05-25 19:21:00+02:00", "height": 358.0, "type": "HW", "phase": "S" },
              { "timestamp": "2026-05-26 01:35:00+02:00", "height": 50.0,  "type": "NW", "phase": null },
              { "timestamp": "2026-05-26 07:48:00+02:00", "height": 362.0, "type": "HW", "phase": "S" }
            ]
          }
        }
      }
    }
    """

    static let bshEmptyJSON: String = """
    {
      "years": {
        "2026": {
          "MHW": null,
          "MNW": null,
          "hwnw_prediction": { "data": [] }
        }
      }
    }
    """

    static let bshMalformedJSON: String = "{ this is not valid json"

    static let bshArrayShapeJSON: String = """
    {
      "years": [
        {
          "2026": {
            "MHW": 350.0,
            "MNW": 50.0,
            "hwnw_prediction": {
              "data": [
                { "timestamp": "2026-05-25 06:42:00+02:00", "height": 360.0, "type": "HW", "phase": "S" }
              ]
            }
          }
        }
      ]
    }
    """

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            fatalError("TestFixtures.date – ungültiges ISO-Datum: \(iso)")
        }
        return date
    }

    static func berlinDate(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let d = f.date(from: string) else {
            fatalError("TestFixtures.berlinDate – ungültiges Datum: \(string)")
        }
        return d
    }
}
