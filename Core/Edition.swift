/// FIT-266: which app this build is. The consumer app (codename Liftplan) builds from the same code with `CONSUMER`
/// set (project.yml): the launch set only (FIT-273), sold with a free trial and then a hard paywall (FIT-267).
enum Edition {
    #if CONSUMER
    static let consumer = true
    #else
    static let consumer = false
    #endif

    /// The name people see, until FIT-265 picks the consumer app's.
    static var name: String { consumer ? "Liftplan" : "Barbrabell" }
}
