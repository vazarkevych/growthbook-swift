import Foundation

/// Interface for Feature API Completion Events
protocol FeaturesFlowDelegate: AnyObject {
    func featuresFetchedSuccessfully(features: Features, isRemote: Bool)
    func featuresAPIModelSuccessfully(model: FeaturesDataModel)
    func featuresFetchFailed(error: SDKError, isRemote: Bool)
    func savedGroupsFetchFailed(error: SDKError, isRemote: Bool)
    func savedGroupsFetchedSuccessfully(savedGroups: JSON, isRemote: Bool)
}

/// View Model for Features
class FeaturesViewModel {
    weak var delegate: FeaturesFlowDelegate?
    var encryptionKey: String?
    
    private let dataSource: FeaturesDataSource
    private let manager: CachingLayer
    private var sseHandler: SSEHandler?
    private let fileSaveQueue = DispatchQueue(label: "com.sdk.fileSaveQueue", qos: .utility)
    
    var forceSynchronousSave: Bool
    let fallbackFeatures: Features?
    
    private let ttlSeconds: Int
    private var expiresAt: TimeInterval?
    private var streamingUpdate: SSEHandler?
    private let retryHandler = NetworkRetryHandler()
        
    init(delegate: FeaturesFlowDelegate, dataSource: FeaturesDataSource, cachingManager: CachingLayer, forceSynchronousSave: Bool = false, ttlSeconds: Int = 60, fallbackFeatures: Features? = nil) {
        self.delegate = delegate
        self.dataSource = dataSource
        self.manager = cachingManager
        self.forceSynchronousSave = forceSynchronousSave
        self.ttlSeconds = ttlSeconds
        self.fallbackFeatures = fallbackFeatures
        self.fetchCachedFeatures()
    }
    
    deinit {
        sseHandler?.disconnect()
    }
    
    private func isCacheExpired() -> Bool {
        guard let expiresAt = expiresAt else {
            return true
        }
        return Date().timeIntervalSince1970 >= expiresAt
    }
    
    private func refreshExpiresAt() {
        expiresAt = Date().timeIntervalSince1970 + Double(ttlSeconds)
    }
        
    func connectBackgroundSync(sseUrl: String, apiUrl: String? = nil) {
        guard let url = URL(string: sseUrl) else { return }
        
        // Disconnect existing connection if any
        sseHandler?.disconnect()
        
        let handler = SSEHandler(url: url)
        self.streamingUpdate = handler
        self.sseHandler = handler

        handler.addEventListener(event: "features") { [weak self] _, _, data in
            guard let self, let jsonData = data?.data(using: .utf8) else { return }
            self.prepareFeaturesData(data: jsonData)
        }

        handler.onDissconnect { [weak self] _, shouldReconnect, _ in
            guard let self = self else { return }
            if shouldReconnect == true {
                self.retryHandler.retryWhenOnline {
                    self.streamingUpdate?.connect()
                }
            }
        }

        if let apiUrl = apiUrl {
            retryHandler.retryWhenOnline {
                logger.info("Connection established, fetching features from remote")
                self.fetchFeatures(apiUrl: apiUrl)
                handler.connect()
            }
        } else {
            handler.connect()
        }
    }
        
    func fetchFeatures(apiUrl: String?, remoteEval: Bool = false, payload: RemoteEvalParams? = nil) {
        let cached = fetchCachedFeatures()
        
        // Check cache expiration if TTL is enabled
        if let cached, !isCacheExpired() {
            notify { $0.featuresFetchedSuccessfully(features: cached, isRemote: false) }
            return
        }
        
        guard let apiUrl else {
            useCachedOrFallback(cached)
            return
        }
        
        let completion: (Result<Data, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                self.prepareFeaturesData(data: data)
            case .failure(let error):
                logger.error("Failed to fetch features: \(error.localizedDescription)")
                self.useCachedOrFallback(cached)
            }
        }
        
        if remoteEval {
            dataSource.fetchRemoteEval(apiUrl: apiUrl, params: payload, fetchResult: completion)
        } else {
            dataSource.fetchFeatures(apiUrl: apiUrl, fetchResult: completion)
        }
    }
    
    private func useCachedOrFallback(_ cached: Features?) {
        if let cached {
            logger.info("Using expired cache as fallback")
            notify { $0.featuresFetchedSuccessfully(features: cached, isRemote: false) }
        } else if let fallback = fallbackFeatures {
            logger.info("Using fallback features")
            notify { $0.featuresFetchedSuccessfully(features: fallback, isRemote: false) }
        } else {
            logger.warning("No cache or fallback features available")
            notify { $0.featuresFetchFailed(error: .failedToLoadData, isRemote: false) }
        }
    }
        
    private func fetchCachedFeatures(logging: Bool = false) -> Features? {
        guard let data = manager.getContent(fileName: Constants.featureCache) else {
            if logging { logger.info("Cache directory is empty. Nothing to fetch.") }
            return nil
        }
        
        let decoder = JSONDecoder()
        
        if let encryptedString = String(data: data, encoding: .utf8),
           let encryptionKey, !encryptionKey.isEmpty {
            
            let crypto: CryptoProtocol = Crypto()
            if let features = crypto.getFeaturesFromEncryptedFeatures(encryptedString: encryptedString, encryptionKey: encryptionKey) {
                return features
            } else {
                if logging { logger.error("Failed get features from cached encrypted features") }
                return nil
            }
            
        } else if let features = try? decoder.decode(Features.self, from: data) {
            return features
        } else {
            if logging { logger.error("Failed to parse local data") }
            return nil
        }
    }
        
    func prepareFeaturesData(data: Data) {
        let decoder = JSONDecoder()
        
        guard let jsonPetitions = try? decoder.decode(FeaturesDataModel.self, from: data) else {
            logger.error("Failed to decode FeaturesDataModel")
            notify { $0.featuresFetchFailed(error: .failedParsedData, isRemote: true) }
            return
        }
        
        notify { $0.featuresAPIModelSuccessfully(model: jsonPetitions) }
        
        if let encryptedString = jsonPetitions.encryptedFeatures {
            handleEncryptedFeatures(encryptedString: encryptedString, jsonPetitions: jsonPetitions)
        } else if let features = jsonPetitions.features {
            handlePlainFeatures(features, jsonPetitions: jsonPetitions)
        } else {
            logger.error("Missing both encrypted and plain features")
            notify { $0.featuresFetchFailed(error: .failedMissingKey, isRemote: true) }
        }
    }
        
    private func handleEncryptedFeatures(encryptedString: String, jsonPetitions: FeaturesDataModel) {
        guard let encryptionKey = encryptionKey, !encryptionKey.isEmpty else {
            logger.error("Missing encryption key")
            notify { $0.featuresFetchFailed(error: .failedMissingKey, isRemote: true) }
            return
        }
        
        let crypto = Crypto()
        guard let features = crypto.getFeaturesFromEncryptedFeatures(encryptedString: encryptedString, encryptionKey: encryptionKey) else {
            logger.error("Failed to decrypt features")
            notify { $0.featuresFetchFailed(error: .failedEncryptedFeatures, isRemote: true) }
            return
        }
        
        // Save encrypted string as-is for encrypted features
        if let featureData = encryptedString.data(using: .utf8) {
            saveDataThreadSafe(fileName: Constants.featureCache, content: featureData)
            refreshExpiresAt()
        } else {
            logger.error("Failed to encode features as UTF-8")
        }
        
        notify { $0.featuresFetchedSuccessfully(features: features, isRemote: true) }
        handleSavedGroups(from: jsonPetitions)
    }
    
    private func handlePlainFeatures(_ features: Features, jsonPetitions: FeaturesDataModel) {
        if let featureData = try? JSONEncoder().encode(features) {
            saveDataThreadSafe(fileName: Constants.featureCache, content: featureData)
            refreshExpiresAt()
        }
        
        notify { $0.featuresFetchedSuccessfully(features: features, isRemote: true) }
        handleSavedGroups(from: jsonPetitions)
    }
    
    private func handleSavedGroups(from jsonPetitions: FeaturesDataModel) {
        if let encryptedSavedGroups = jsonPetitions.encryptedSavedGroups,
           !encryptedSavedGroups.isEmpty,
           let encryptionKey = encryptionKey,
           !encryptionKey.isEmpty {
            
            let crypto = Crypto()
            if let savedGroups = crypto.getSavedGroupsFromEncryptedFeatures(encryptedString: encryptedSavedGroups, encryptionKey: encryptionKey) {
                if let savedGroupsData = encryptedSavedGroups.data(using: .utf8) {
                    saveDataThreadSafe(fileName: Constants.savedGroupsCache, content: savedGroupsData)
                }
                notify { $0.savedGroupsFetchedSuccessfully(savedGroups: savedGroups, isRemote: true) }
            } else {
                logger.error("Failed to decrypt saved groups")
                notify { $0.savedGroupsFetchFailed(error: .failedEncryptedSavedGroups, isRemote: true) }
            }
            
        } else if let savedGroups = jsonPetitions.savedGroups {
            if let savedGroupsData = try? JSONEncoder().encode(savedGroups) {
                saveDataThreadSafe(fileName: Constants.savedGroupsCache, content: savedGroupsData)
            }
            notify { $0.savedGroupsFetchedSuccessfully(savedGroups: savedGroups, isRemote: true) }
        }
    }
        
    private func saveDataThreadSafe(fileName: String, content: Data) {
        if forceSynchronousSave {
            manager.saveContent(fileName: fileName, content: content)
            return
        } else {
            fileSaveQueue.async { [weak self] in
                self?.manager.saveContent(fileName: fileName, content: content)
            }
        }
    }
        
    private func notify(_ action: @escaping (FeaturesFlowDelegate) -> Void) {
        if Thread.isMainThread {
            guard let delegate = self.delegate else { return }
            action(delegate)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let delegate = self.delegate else { return }
                action(delegate)
            }
        }
    }
}
