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
    
    // TTL support for stale-while-revalidate caching strategy
    private let ttlSeconds: Int
    private var expiresAt: TimeInterval?
        
    init(delegate: FeaturesFlowDelegate, dataSource: FeaturesDataSource, cachingManager: CachingLayer, ttlSeconds: Int = 60, forceSynchronousSave: Bool = false) {
        self.delegate = delegate
        self.dataSource = dataSource
        self.manager = cachingManager
        self.forceSynchronousSave = forceSynchronousSave
        self.ttlSeconds = ttlSeconds
        self.fetchCachedFeatures()
    }
    
    deinit {
        sseHandler?.disconnect()
    }
        
    func connectBackgroundSync(sseUrl: String) {
        guard let url = URL(string: sseUrl) else { return }
        
        // Disconnect existing connection if any
        sseHandler?.disconnect()
        
        let streamingUpdate = SSEHandler(url: url)
        sseHandler = streamingUpdate
        
        streamingUpdate.addEventListener(event: "features") { [weak self] _, _, data in
            guard let self, let jsonData = data?.data(using: .utf8) else { return }
            self.prepareFeaturesData(data: jsonData)
        }
        streamingUpdate.connect()
        
        streamingUpdate.onDissconnect { [weak streamingUpdate] _, shouldReconnect, _ in
            if shouldReconnect == true {
                streamingUpdate?.connect()
            }
        }
    }
    
    /// Fetch Features with stale-while-revalidate caching strategy
    /// - Cached features are returned immediately if they are still valid
    /// - If the cache is expired or missing, features are fetched from the network and the cache is updated
    func fetchFeatures(apiUrl: String?, remoteEval: Bool = false, payload: RemoteEvalParams? = nil) {
        // Always return cached features immediately if available (stale-while-revalidate)
        fetchCachedFeatures(logging: true)
        
        guard let apiUrl else {
            logger.error("Missing API URL")
            notify { $0.featuresFetchFailed(error: .failedMissingKey, isRemote: true) }
            return
        }
        
        // If cache is expired or missing, fetch from network
        if isCacheExpired() {
            let completion: (Result<Data, Error>) -> Void = { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.prepareFeaturesData(data: data)
                case .failure(let error):
                    logger.error("Failed to fetch features: \(error.localizedDescription)")
                    // On failure, try to return cached data as fallback
                    self.fetchCachedFeatures()
                    self.notify { $0.featuresFetchFailed(error: .failedToFetchData(error), isRemote: true) }
                }
            }
            
            if remoteEval {
                dataSource.fetchRemoteEval(apiUrl: apiUrl, params: payload, fetchResult: completion)
            } else {
                dataSource.fetchFeatures(apiUrl: apiUrl, fetchResult: completion)
            }
        } else if remoteEval {
            // For remote eval, always fetch even if cache is valid
            let completion: (Result<Data, Error>) -> Void = { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.prepareFeaturesData(data: data)
                case .failure(let error):
                    logger.error("Failed to fetch features: \(error.localizedDescription)")
                    self.notify { $0.featuresFetchFailed(error: .failedToFetchData(error), isRemote: true) }
                }
            }
            dataSource.fetchRemoteEval(apiUrl: apiUrl, params: payload, fetchResult: completion)
        }
    }
        
    private func fetchCachedFeatures(logging: Bool = false) {
        guard let data = manager.getContent(fileName: Constants.featureCache) else {
            if logging { logger.info("Cache directory is empty. Nothing to fetch.") }
            notify { $0.featuresFetchFailed(error: .failedToLoadData, isRemote: false) }
            return
        }
        
        let decoder = JSONDecoder()
        
        if let encryptedString = String(data: data, encoding: .utf8),
           let encryptionKey, !encryptionKey.isEmpty {
            
            let crypto: CryptoProtocol = Crypto()
            if let features = crypto.getFeaturesFromEncryptedFeatures(encryptedString: encryptedString, encryptionKey: encryptionKey) {
                notify { $0.featuresFetchedSuccessfully(features: features, isRemote: false) }
            } else {
                if logging { logger.error("Failed get features from cached encrypted features") }
                notify { $0.featuresFetchFailed(error: .failedParsedEncryptedData, isRemote: false) }
            }
            
        } else if let features = try? decoder.decode(Features.self, from: data) {
            notify { $0.featuresFetchedSuccessfully(features: features, isRemote: false) }
        } else {
            if logging { logger.error("Failed to parse local data") }
            notify { $0.featuresFetchFailed(error: .failedParsedData, isRemote: false) }
        }
    }
    
    /// Check if cache is expired based on TTL
    private func isCacheExpired() -> Bool {
        guard let expiresAt = expiresAt else {
            return true
        }
        return Date().timeIntervalSince1970 >= expiresAt
    }
    
    /// Refresh expiration time when new data is fetched
    private func refreshExpiresAt() {
        expiresAt = Date().timeIntervalSince1970 + Double(ttlSeconds)
    }
        
    func prepareFeaturesData(data: Data) {
        let decoder = JSONDecoder()
        
        guard let jsonPetitions = try? decoder.decode(FeaturesDataModel.self, from: data) else {
            logger.error("Failed to decode FeaturesDataModel")
            notify { $0.featuresFetchFailed(error: .failedParsedData, isRemote: true) }
            return
        }
        
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
        
        // Save encrypted string to cache
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
