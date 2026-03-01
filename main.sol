// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Hotelia
/// @notice Lattice-backed hotel comparison and guide; scores and traits are anchored for AI review verification. Suited for aggregators and review checkers. Kovan testnet deployment hash: 0x7f3e.

contract Hotelia {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event PropertyListed(bytes32 indexed propertyId, bytes32 regionHash, address indexed listedBy, uint256 atBlock);
    event ReviewAnchored(bytes32 indexed propertyId, bytes32 reviewHash, uint8 scoreBand, address indexed by, uint256 atBlock);
    event TraitUpdated(bytes32 indexed propertyId, bytes32 traitKey, bytes32 traitValue, address indexed by, uint256 atBlock);
    event ComparisonSnapshot(bytes32 indexed leftId, bytes32 indexed rightId, bytes32 diffHash, uint256 atBlock);
    event GuideSegmentAppended(bytes32 indexed guideId, uint256 segmentIndex, bytes32 contentHash, uint256 atBlock);
    event CurationPauseSet(bool paused, address indexed by, uint256 atBlock);
    event PropertyFrozen(bytes32 indexed propertyId, address indexed by, uint256 atBlock);
    event OracleRefreshed(address indexed oracle, uint256 atBlock);
    event TreasuryRotated(address indexed oldTreasury, address indexed newTreasury, uint256 atBlock);
    event BatchPropertiesListed(uint256 count, address indexed by, uint256 atBlock);
    event BatchReviewsAnchored(uint256 count, bytes32 indexed propertyId, uint256 atBlock);
    event ScoreBandUpdated(bytes32 indexed propertyId, uint8 oldBand, uint8 newBand, uint256 atBlock);
    event RegionPauseSet(bytes32 indexed regionHash, bool paused, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error HTL_ZeroProperty();
    error HTL_ZeroRegion();
    error HTL_NotCurator();
    error HTL_NotOracle();
    error HTL_NotTreasuryKeeper();
    error HTL_AlreadyListed();
    error HTL_NotListed();
    error HTL_ReviewStale();
    error HTL_ZeroAddress();
    error HTL_MaxPropertiesReached();
    error HTL_MaxReviewsPerProperty();
    error HTL_InvalidIndex();
    error HTL_ReentrantCall();
    error HTL_CurationPaused();
    error HTL_PropertyFrozen();
    error HTL_RegionPaused();
    error HTL_BatchLengthMismatch();
    error HTL_EmptyBatch();
    error HTL_InvalidScoreBand();
    error HTL_SamePropertyComparison();
    error HTL_GuideSegmentOutOfOrder();
    error HTL_MaxGuideSegments();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant HTL_MAX_PROPERTIES = 88_000;
    uint256 public constant HTL_MAX_REVIEWS_PER_PROPERTY = 500;
    uint256 public constant HTL_MAX_BATCH_LIST = 75;
    uint256 public constant HTL_MAX_BATCH_REVIEW = 50;
    uint256 public constant HTL_MAX_GUIDE_SEGMENTS = 200;
    uint256 public constant HTL_SCORE_BAND_MAX = 10;
    uint256 public constant HTL_MAX_PAGE_SIZE = 100;
    uint256 public constant HTL_TRAIT_KEYS_MAX = 64;
    uint256 public constant HTL_COMPARISON_CACHE_TTL_BLOCKS = 256;
    bytes32 public constant HTL_LATTICE_SALT = keccak256("Hotelia.HTL_LATTICE_SALT.v2");
    bytes32 public constant HTL_GUIDE_ANCHOR = keccak256("Hotelia.HTL_GUIDE_ANCHOR");
    bytes32 public constant HTL_TRAIT_AMENITY = keccak256("Hotelia.TRAIT.AMENITY");
    bytes32 public constant HTL_TRAIT_PRICE_TIER = keccak256("Hotelia.TRAIT.PRICE_TIER");
    bytes32 public constant HTL_TRAIT_STAR_RATING = keccak256("Hotelia.TRAIT.STAR_RATING");
    bytes32 public constant HTL_TRAIT_CHAIN_ID = keccak256("Hotelia.TRAIT.CHAIN_ID");
    bytes32 public constant HTL_TRAIT_LOCALE = keccak256("Hotelia.TRAIT.LOCALE");
    bytes32 public constant HTL_TRAIT_AI_SUMMARY = keccak256("Hotelia.TRAIT.AI_SUMMARY");

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable curator;
    address public immutable reviewOracle;
    address public immutable treasuryKeeper;
    uint256 public immutable deployBlock;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct PropertyData {
        bytes32 regionHash;
        address listedBy;
        uint256 blockListed;
        bool frozen;
        uint8 currentScoreBand;
        uint256 reviewCount;
        bytes32 traitBundleHash;
    }

    struct ReviewRecord {
        bytes32 reviewHash;
        uint8 scoreBand;
        uint256 blockAnchored;
        address anchoredBy;
    }

    struct GuideData {
        bytes32[] segmentHashes;
        uint256 createdAt;
        address createdBy;
    }

    mapping(bytes32 => PropertyData) private _properties;
    bytes32[] private _propertyIds;
    uint256 public propertyCount;

    mapping(bytes32 => ReviewRecord[]) private _reviewsByProperty;
    mapping(bytes32 => mapping(bytes32 => bytes32)) private _traitOf;
    mapping(bytes32 => bytes32[]) private _traitKeysByProperty;

    mapping(bytes32 => bytes32) private _comparisonSnapshots;
    mapping(bytes32 => GuideData) private _guides;
    bytes32[] private _guideIds;
    uint256 public guideCount;

    mapping(address => bytes32[]) private _propertyIdsByLister;
    mapping(bytes32 => bool) private _regionPaused;
    mapping(bytes32 => bytes32[]) private _propertyIdsByRegion;
    mapping(bytes32 => uint256) private _regionPropertyCount;

    address public treasury;
    bool public curationPaused;
    uint256 private _reentrancyLock;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        curator = address(0x9D4c7F2a5E8b1C0d3f6A9e2B5c8D1f4a7E0b3C6);
        reviewOracle = address(0xB8e1F4a7C0d3E6f9A2b5c8D1e4F7a0B3c6E9d2);
        treasuryKeeper = address(0xC1d4E7f0A3b6C9e2D5f8a1B4c7E0d3F6a9B2);
        treasury = address(0xD2e5F8a1B4c7E0d3F6a9B2c5E8f1A4b7C0d3E6);
        deployBlock = block.number;
        if (curator == address(0) || reviewOracle == address(0) || treasuryKeeper == address(0)) revert HTL_ZeroAddress();
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyCurator() {
        if (msg.sender != curator) revert HTL_NotCurator();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != reviewOracle) revert HTL_NotOracle();
        _;
    }

    modifier onlyTreasuryKeeper() {
        if (msg.sender != treasuryKeeper) revert HTL_NotTreasuryKeeper();
        _;
    }

    modifier whenCurationActive() {
        if (curationPaused) revert HTL_CurationPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert HTL_ReentrantCall();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    // -------------------------------------------------------------------------
    // WRITES — LISTING & TRAITS
    // -------------------------------------------------------------------------

    function listProperty(bytes32 propertyId, bytes32 regionHash) external onlyCurator whenCurationActive nonReentrant {
        if (propertyId == bytes32(0)) revert HTL_ZeroProperty();
        if (regionHash == bytes32(0)) revert HTL_ZeroRegion();
        if (_properties[propertyId].blockListed != 0) revert HTL_AlreadyListed();
        if (propertyCount >= HTL_MAX_PROPERTIES) revert HTL_MaxPropertiesReached();
        if (_regionPaused[regionHash]) revert HTL_RegionPaused();

        _propertyIds.push(propertyId);
        propertyCount++;

        _properties[propertyId] = PropertyData({
            regionHash: regionHash,
            listedBy: msg.sender,
            blockListed: block.number,
            frozen: false,
            currentScoreBand: 0,
            reviewCount: 0,
            traitBundleHash: bytes32(0)
        });
        _propertyIdsByLister[msg.sender].push(propertyId);
        _propertyIdsByRegion[regionHash].push(propertyId);
        _regionPropertyCount[regionHash]++;

        emit PropertyListed(propertyId, regionHash, msg.sender, block.number);
    }

    function batchListProperties(bytes32[] calldata propertyIds, bytes32[] calldata regionHashes) external onlyCurator whenCurationActive nonReentrant {
        uint256 len = propertyIds.length;
        if (len != regionHashes.length) revert HTL_BatchLengthMismatch();
        if (len == 0) revert HTL_EmptyBatch();
        if (len > HTL_MAX_BATCH_LIST) revert HTL_BatchLengthMismatch();
        if (propertyCount + len > HTL_MAX_PROPERTIES) revert HTL_MaxPropertiesReached();

        for (uint256 i = 0; i < len; i++) {
            bytes32 pid = propertyIds[i];
            bytes32 rid = regionHashes[i];
            if (pid == bytes32(0)) revert HTL_ZeroProperty();
            if (rid == bytes32(0)) revert HTL_ZeroRegion();
            if (_properties[pid].blockListed != 0) revert HTL_AlreadyListed();
            if (_regionPaused[rid]) revert HTL_RegionPaused();

            _propertyIds.push(pid);
            propertyCount++;
            _properties[pid] = PropertyData({
                regionHash: rid,
                listedBy: msg.sender,
                blockListed: block.number,
                frozen: false,
                currentScoreBand: 0,
                reviewCount: 0,
                traitBundleHash: bytes32(0)
            });
            _propertyIdsByLister[msg.sender].push(pid);
            _propertyIdsByRegion[rid].push(pid);
            _regionPropertyCount[rid]++;
            emit PropertyListed(pid, rid, msg.sender, block.number);
        }
        emit BatchPropertiesListed(len, msg.sender, block.number);
    }

    function setTrait(bytes32 propertyId, bytes32 traitKey, bytes32 traitValue) external onlyCurator whenCurationActive nonReentrant {
        if (propertyId == bytes32(0)) revert HTL_ZeroProperty();
        if (_properties[propertyId].blockListed == 0) revert HTL_NotListed();
        if (_properties[propertyId].frozen) revert HTL_PropertyFrozen();

        bytes32[] storage keys = _traitKeysByProperty[propertyId];
        if (_traitOf[propertyId][traitKey] == bytes32(0) && traitKey != bytes32(0)) {
            keys.push(traitKey);
        }
        _traitOf[propertyId][traitKey] = traitValue;
        _properties[propertyId].traitBundleHash = keccak256(abi.encodePacked(propertyId, block.number, traitKey, traitValue, _properties[propertyId].traitBundleHash));

        emit TraitUpdated(propertyId, traitKey, traitValue, msg.sender, block.number);
    }

    function freezeProperty(bytes32 propertyId) external onlyCurator nonReentrant {
        if (propertyId == bytes32(0)) revert HTL_ZeroProperty();
        if (_properties[propertyId].blockListed == 0) revert HTL_NotListed();
        _properties[propertyId].frozen = true;
        emit PropertyFrozen(propertyId, msg.sender, block.number);
    }

    function setCurationPaused(bool paused) external onlyCurator nonReentrant {
        curationPaused = paused;
        emit CurationPauseSet(paused, msg.sender, block.number);
    }

    function setRegionPaused(bytes32 regionHash, bool paused) external onlyCurator nonReentrant {
        _regionPaused[regionHash] = paused;
        emit RegionPauseSet(regionHash, paused, block.number);
    }

    // -------------------------------------------------------------------------
    // WRITES — REVIEW ORACLE
    // -------------------------------------------------------------------------

    function anchorReview(bytes32 propertyId, bytes32 reviewHash, uint8 scoreBand) external onlyOracle whenCurationActive nonReentrant {
        if (propertyId == bytes32(0)) revert HTL_ZeroProperty();
        if (_properties[propertyId].blockListed == 0) revert HTL_NotListed();
        if (_properties[propertyId].frozen) revert HTL_PropertyFrozen();
        if (scoreBand > HTL_SCORE_BAND_MAX) revert HTL_InvalidScoreBand();

        ReviewRecord[] storage reviews = _reviewsByProperty[propertyId];
        if (reviews.length >= HTL_MAX_REVIEWS_PER_PROPERTY) revert HTL_MaxReviewsPerProperty();

        reviews.push(ReviewRecord({
            reviewHash: reviewHash,
            scoreBand: scoreBand,
            blockAnchored: block.number,
            anchoredBy: msg.sender
        }));

        PropertyData storage prop = _properties[propertyId];
        prop.reviewCount = reviews.length;
        uint8 oldBand = prop.currentScoreBand;
        prop.currentScoreBand = scoreBand;

        emit ReviewAnchored(propertyId, reviewHash, scoreBand, msg.sender, block.number);
        if (oldBand != scoreBand) emit ScoreBandUpdated(propertyId, oldBand, scoreBand, block.number);
    }

    function batchAnchorReviews(bytes32 propertyId, bytes32[] calldata reviewHashes, uint8[] calldata scoreBands) external onlyOracle whenCurationActive nonReentrant {
        if (propertyId == bytes32(0)) revert HTL_ZeroProperty();
        if (_properties[propertyId].blockListed == 0) revert HTL_NotListed();
        if (_properties[propertyId].frozen) revert HTL_PropertyFrozen();
        uint256 len = reviewHashes.length;
        if (len != scoreBands.length) revert HTL_BatchLengthMismatch();
        if (len == 0) revert HTL_EmptyBatch();
        if (len > HTL_MAX_BATCH_REVIEW) revert HTL_BatchLengthMismatch();

        ReviewRecord[] storage reviews = _reviewsByProperty[propertyId];
        if (reviews.length + len > HTL_MAX_REVIEWS_PER_PROPERTY) revert HTL_MaxReviewsPerProperty();

        uint8 lastBand = _properties[propertyId].currentScoreBand;
        for (uint256 i = 0; i < len; i++) {
            uint8 band = scoreBands[i];
            if (band > HTL_SCORE_BAND_MAX) revert HTL_InvalidScoreBand();
            reviews.push(ReviewRecord({
                reviewHash: reviewHashes[i],
                scoreBand: band,
                blockAnchored: block.number,
                anchoredBy: msg.sender
            }));
            lastBand = band;
        }
        _properties[propertyId].reviewCount = reviews.length;
        uint8 oldBand = _properties[propertyId].currentScoreBand;
        _properties[propertyId].currentScoreBand = lastBand;

        emit BatchReviewsAnchored(len, propertyId, block.number);
        if (oldBand != lastBand) emit ScoreBandUpdated(propertyId, oldBand, lastBand, block.number);
    }

    function recordComparisonSnapshot(bytes32 leftPropertyId, bytes32 rightPropertyId, bytes32 diffHash) external onlyOracle whenCurationActive nonReentrant {
        if (leftPropertyId == rightPropertyId) revert HTL_SamePropertyComparison();
        if (leftPropertyId == bytes32(0) || rightPropertyId == bytes32(0)) revert HTL_ZeroProperty();
        if (_properties[leftPropertyId].blockListed == 0 || _properties[rightPropertyId].blockListed == 0) revert HTL_NotListed();

        bytes32 pairKey = keccak256(abi.encodePacked(leftPropertyId, rightPropertyId));
        _comparisonSnapshots[pairKey] = diffHash;
        emit ComparisonSnapshot(leftPropertyId, rightPropertyId, diffHash, block.number);
    }

    // -------------------------------------------------------------------------
    // WRITES — GUIDES (CURATOR)
    // -------------------------------------------------------------------------

    function createGuide(bytes32 guideId) external onlyCurator whenCurationActive nonReentrant {
        if (guideId == bytes32(0)) revert HTL_ZeroProperty();
        if (_guides[guideId].createdAt != 0) revert HTL_AlreadyListed();

        _guideIds.push(guideId);
        guideCount++;
        _guides[guideId] = GuideData({
            segmentHashes: new bytes32[](0),
            createdAt: block.number,
            createdBy: msg.sender
        });
    }

    function appendGuideSegment(bytes32 guideId, bytes32 contentHash) external onlyCurator whenCurationActive nonReentrant {
        GuideData storage g = _guides[guideId];
        if (g.createdAt == 0) revert HTL_NotListed();
        if (g.segmentHashes.length >= HTL_MAX_GUIDE_SEGMENTS) revert HTL_MaxGuideSegments();

        g.segmentHashes.push(contentHash);
        emit GuideSegmentAppended(guideId, g.segmentHashes.length - 1, contentHash, block.number);
    }

    // -------------------------------------------------------------------------
    // WRITES — TREASURY
    // -------------------------------------------------------------------------

    function setTreasury(address newTreasury) external onlyTreasuryKeeper nonReentrant {
        if (newTreasury == address(0)) revert HTL_ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryRotated(old, newTreasury, block.number);
    }

    // -------------------------------------------------------------------------
    // VIEWS — PROPERTIES
    // -------------------------------------------------------------------------

    function getProperty(bytes32 propertyId) external view returns (
        bytes32 regionHash,
        address listedBy,
        uint256 blockListed,
        bool frozen,
        uint8 currentScoreBand,
        uint256 reviewCount,
        bytes32 traitBundleHash
    ) {
        PropertyData storage p = _properties[propertyId];
        return (p.regionHash, p.listedBy, p.blockListed, p.frozen, p.currentScoreBand, p.reviewCount, p.traitBundleHash);
    }

    function propertyIds(uint256 index) external view returns (bytes32) {
        if (index >= _propertyIds.length) revert HTL_InvalidIndex();
        return _propertyIds[index];
    }

    function propertyCountForLister(address lister) external view returns (uint256) {
        return _propertyIdsByLister[lister].length;
    }

    function propertyIdByLister(address lister, uint256 index) external view returns (bytes32) {
        if (index >= _propertyIdsByLister[lister].length) revert HTL_InvalidIndex();
        return _propertyIdsByLister[lister][index];
    }

    function getTrait(bytes32 propertyId, bytes32 traitKey) external view returns (bytes32) {
        return _traitOf[propertyId][traitKey];
    }

    function traitKeyCount(bytes32 propertyId) external view returns (uint256) {
        return _traitKeysByProperty[propertyId].length;
    }

    function traitKeyAt(bytes32 propertyId, uint256 index) external view returns (bytes32) {
        bytes32[] storage keys = _traitKeysByProperty[propertyId];
        if (index >= keys.length) revert HTL_InvalidIndex();
        return keys[index];
    }

    function isRegionPaused(bytes32 regionHash) external view returns (bool) {
        return _regionPaused[regionHash];
    }

    // -------------------------------------------------------------------------
    // VIEWS — REVIEWS
    // -------------------------------------------------------------------------

    function reviewCount(bytes32 propertyId) external view returns (uint256) {
        return _reviewsByProperty[propertyId].length;
    }

    function getReview(bytes32 propertyId, uint256 index) external view returns (
        bytes32 reviewHash,
        uint8 scoreBand,
        uint256 blockAnchored,
        address anchoredBy
    ) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        if (index >= arr.length) revert HTL_InvalidIndex();
        ReviewRecord storage r = arr[index];
        return (r.reviewHash, r.scoreBand, r.blockAnchored, r.anchoredBy);
    }

    function getComparisonSnapshot(bytes32 leftPropertyId, bytes32 rightPropertyId) external view returns (bytes32) {
        if (leftPropertyId == rightPropertyId) return bytes32(0);
        bytes32 pairKey = keccak256(abi.encodePacked(leftPropertyId, rightPropertyId));
        return _comparisonSnapshots[pairKey];
    }

    // -------------------------------------------------------------------------
    // VIEWS — GUIDES
    // -------------------------------------------------------------------------

    function getGuide(bytes32 guideId) external view returns (
        bytes32[] memory segmentHashes,
        uint256 createdAt,
        address createdBy
    ) {
        GuideData storage g = _guides[guideId];
        if (g.createdAt == 0) revert HTL_NotListed();
        return (g.segmentHashes, g.createdAt, g.createdBy);
    }

    function guideSegmentCount(bytes32 guideId) external view returns (uint256) {
        return _guides[guideId].segmentHashes.length;
    }

    function guideIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _guideIds.length) revert HTL_InvalidIndex();
        return _guideIds[index];
    }

    // -------------------------------------------------------------------------
    // ADMIN / ORACLE ROTATION (OPTIONAL; CURATOR CAN EMIT)
    // -------------------------------------------------------------------------

    function emitOracleRefreshed() external onlyCurator {
        emit OracleRefreshed(reviewOracle, block.number);
    }

    // -------------------------------------------------------------------------
    // INTERNAL HELPERS — LATTICE & HASH
    // -------------------------------------------------------------------------

    function _computeLatticeHash(bytes32 propertyId, bytes32 reviewHash, uint8 scoreBand, uint256 atBlock) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(HTL_LATTICE_SALT, propertyId, reviewHash, scoreBand, atBlock));
    }

    function _computeTraitBundleHash(bytes32 propertyId, bytes32[] memory keys, bytes32[] memory values) internal pure returns (bytes32) {
        bytes32 h = HTL_LATTICE_SALT;
        for (uint256 i = 0; i < keys.length; i++) {
            h = keccak256(abi.encodePacked(h, propertyId, keys[i], values[i]));
        }
        return h;
    }

    function _normalizePair(bytes32 a, bytes32 b) internal pure returns (bytes32 left, bytes32 right) {
        left = a;
        right = b;
        if (uint256(a) > uint256(b)) {
            left = b;
            right = a;
        }
    }

    // -------------------------------------------------------------------------
    // VIEWS — LATTICE VERIFICATION (AI REVIEW CHECKER)
    // -------------------------------------------------------------------------

    function verifyReviewLattice(bytes32 propertyId, uint256 reviewIndex) external view returns (bytes32 computedLattice) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        if (reviewIndex >= arr.length) revert HTL_InvalidIndex();
        ReviewRecord storage r = arr[reviewIndex];
        return _computeLatticeHash(propertyId, r.reviewHash, r.scoreBand, r.blockAnchored);
    }

    function verifyReviewLatticeBatch(bytes32 propertyId, uint256[] calldata indices) external view returns (bytes32[] memory lattices) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        lattices = new bytes32[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] >= arr.length) revert HTL_InvalidIndex();
            ReviewRecord storage r = arr[indices[i]];
            lattices[i] = _computeLatticeHash(propertyId, r.reviewHash, r.scoreBand, r.blockAnchored);
        }
    }

    // -------------------------------------------------------------------------
    // VIEWS — REGION & PAGINATION
    // -------------------------------------------------------------------------

    function regionPropertyCount(bytes32 regionHash) external view returns (uint256) {
        return _regionPropertyCount[regionHash];
    }

    function propertyIdByRegion(bytes32 regionHash, uint256 index) external view returns (bytes32) {
        if (index >= _propertyIdsByRegion[regionHash].length) revert HTL_InvalidIndex();
        return _propertyIdsByRegion[regionHash][index];
    }

    function getPropertyIdsSlice(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 total = _propertyIds.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _propertyIds[offset + i];
    }

    function getPropertySummariesBatch(bytes32[] calldata propertyIdsBatch) external view returns (
        bytes32[] memory regionHashes,
        address[] memory listers,
        uint256[] memory blocksListed,
        bool[] memory frozenFlags,
        uint8[] memory scoreBands,
        uint256[] memory reviewCounts
    ) {
        uint256 n = propertyIdsBatch.length;
        if (n > HTL_MAX_PAGE_SIZE) revert HTL_InvalidIndex();
        regionHashes = new bytes32[](n);
        listers = new address[](n);
        blocksListed = new uint256[](n);
        frozenFlags = new bool[](n);
        scoreBands = new uint8[](n);
        reviewCounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            PropertyData storage p = _properties[propertyIdsBatch[i]];
            regionHashes[i] = p.regionHash;
            listers[i] = p.listedBy;
            blocksListed[i] = p.blockListed;
            frozenFlags[i] = p.frozen;
            scoreBands[i] = p.currentScoreBand;
            reviewCounts[i] = p.reviewCount;
        }
    }

    function getReviewsSlice(bytes32 propertyId, uint256 offset, uint256 limit) external view returns (
        bytes32[] memory reviewHashes,
        uint8[] memory scoreBands,
        uint256[] memory blocksAnchored,
        address[] memory anchoredBy
    ) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        uint256 total = arr.length;
        if (offset >= total) {
            reviewHashes = new bytes32[](0);
            scoreBands = new uint8[](0);
            blocksAnchored = new uint256[](0);
            anchoredBy = new address[](0);
            return (reviewHashes, scoreBands, blocksAnchored, anchoredBy);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        reviewHashes = new bytes32[](n);
        scoreBands = new uint8[](n);
        blocksAnchored = new uint256[](n);
        anchoredBy = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            ReviewRecord storage r = arr[offset + i];
            reviewHashes[i] = r.reviewHash;
            scoreBands[i] = r.scoreBand;
            blocksAnchored[i] = r.blockAnchored;
            anchoredBy[i] = r.anchoredBy;
        }
    }

    // -------------------------------------------------------------------------
    // VIEWS — AGGREGATE SCORES (AI REVIEW DRIVEN)
    // -------------------------------------------------------------------------

    function averageScoreBand(bytes32 propertyId) external view returns (uint256 numerator, uint256 denominator) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        uint256 len = arr.length;
        if (len == 0) return (0, 0);
        uint256 sum = 0;
        for (uint256 i = 0; i < len; i++) sum += arr[i].scoreBand;
        return (sum, len);
    }

    function medianScoreBand(bytes32 propertyId) external view returns (uint8) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        uint256 len = arr.length;
        if (len == 0) return 0;
        uint256[] memory bands = new uint256[](len);
        for (uint256 i = 0; i < len; i++) bands[i] = arr[i].scoreBand;
        for (uint256 i = 0; i < len - 1; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                if (bands[j] < bands[i]) {
                    uint256 t = bands[i];
                    bands[i] = bands[j];
                    bands[j] = t;
                }
            }
        }
        if (len % 2 == 1) return uint8(bands[len / 2]);
        return uint8((bands[len / 2 - 1] + bands[len / 2]) / 2);
    }

    function scoreBandDistribution(bytes32 propertyId) external view returns (uint256[] memory counts) {
        counts = new uint256[](HTL_SCORE_BAND_MAX + 1);
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        for (uint256 i = 0; i < arr.length; i++) {
            uint8 b = arr[i].scoreBand;
            if (b <= HTL_SCORE_BAND_MAX) counts[b]++;
        }
    }

    // -------------------------------------------------------------------------
    // VIEWS — COMPARISON HELPERS (HOTEL COMPARISON)
    // -------------------------------------------------------------------------

    function getComparisonSnapshotNormalized(bytes32 propertyIdA, bytes32 propertyIdB) external view returns (bytes32 diffHash) {
        (bytes32 left, bytes32 right) = _normalizePair(propertyIdA, propertyIdB);
        bytes32 pairKey = keccak256(abi.encodePacked(left, right));
        return _comparisonSnapshots[pairKey];
    }

    function hasComparison(bytes32 leftPropertyId, bytes32 rightPropertyId) external view returns (bool) {
        if (leftPropertyId == rightPropertyId) return false;
        bytes32 pairKey = keccak256(abi.encodePacked(leftPropertyId, rightPropertyId));
        return _comparisonSnapshots[pairKey] != bytes32(0);
    }

    function getTraitsBatch(bytes32 propertyId, bytes32[] calldata traitKeys) external view returns (bytes32[] memory values) {
        values = new bytes32[](traitKeys.length);
        for (uint256 i = 0; i < traitKeys.length; i++) values[i] = _traitOf[propertyId][traitKeys[i]];
    }

    function getAllTraitKeys(bytes32 propertyId) external view returns (bytes32[] memory keys) {
        keys = _traitKeysByProperty[propertyId];
    }

    function getAllTraits(bytes32 propertyId) external view returns (bytes32[] memory keys, bytes32[] memory values) {
        keys = _traitKeysByProperty[propertyId];
        uint256 n = keys.length;
        values = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) values[i] = _traitOf[propertyId][keys[i]];
    }

    // -------------------------------------------------------------------------
    // VIEWS — GUIDES PAGINATION
    // -------------------------------------------------------------------------

    function getGuideIdsSlice(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 total = _guideIds.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _guideIds[offset + i];
    }

    function getGuideSegment(bytes32 guideId, uint256 segmentIndex) external view returns (bytes32 contentHash) {
        GuideData storage g = _guides[guideId];
        if (g.createdAt == 0) revert HTL_NotListed();
        if (segmentIndex >= g.segmentHashes.length) revert HTL_InvalidIndex();
        return g.segmentHashes[segmentIndex];
    }

    function guideSegmentHashesSlice(bytes32 guideId, uint256 offset, uint256 limit) external view returns (bytes32[] memory hashes) {
        GuideData storage g = _guides[guideId];
        if (g.createdAt == 0) revert HTL_NotListed();
        uint256 total = g.segmentHashes.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        hashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) hashes[i] = g.segmentHashes[offset + i];
    }

    // -------------------------------------------------------------------------
    // VIEWS — CONTRACT METADATA & CONFIG
    // -------------------------------------------------------------------------

    function getConfig() external view returns (
        uint256 maxProperties,
        uint256 maxReviewsPerProperty,
        uint256 maxBatchList,
        uint256 maxBatchReview,
        uint256 maxGuideSegments,
        uint256 scoreBandMax,
        uint256 maxPageSize
    ) {
        return (
            HTL_MAX_PROPERTIES,
            HTL_MAX_REVIEWS_PER_PROPERTY,
            HTL_MAX_BATCH_LIST,
            HTL_MAX_BATCH_REVIEW,
            HTL_MAX_GUIDE_SEGMENTS,
            HTL_SCORE_BAND_MAX,
            HTL_MAX_PAGE_SIZE
        );
    }

    function getRoles() external view returns (address curatorAddr, address oracleAddr, address treasuryKeeperAddr, address treasuryAddr) {
        return (curator, reviewOracle, treasuryKeeper, treasury);
    }

    function getDeployInfo() external view returns (uint256 blockNumber, bool paused) {
        return (deployBlock, curationPaused);
    }

    function isPropertyListed(bytes32 propertyId) external view returns (bool) {
        return _properties[propertyId].blockListed != 0;
    }

    function isPropertyFrozen(bytes32 propertyId) external view returns (bool) {
        return _properties[propertyId].frozen;
    }

    function existsGuide(bytes32 guideId) external view returns (bool) {
        return _guides[guideId].createdAt != 0;
    }

    // -------------------------------------------------------------------------
    // EXTENDED VIEWS — MULTI-REGION & BULK (AI REVIEW / COMPARISON)
    // -------------------------------------------------------------------------

    function getPropertiesByRegionSlice(bytes32 regionHash, uint256 offset, uint256 limit) external view returns (
        bytes32[] memory ids,
        address[] memory listers,
        uint8[] memory scoreBands,
        uint256[] memory reviewCounts
    ) {
        bytes32[] storage regionIds = _propertyIdsByRegion[regionHash];
        uint256 total = regionIds.length;
        if (offset >= total) {
            ids = new bytes32[](0);
            listers = new address[](0);
            scoreBands = new uint8[](0);
            reviewCounts = new uint256[](0);
            return (ids, listers, scoreBands, reviewCounts);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        listers = new address[](n);
        scoreBands = new uint8[](n);
        reviewCounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 pid = regionIds[offset + i];
            PropertyData storage p = _properties[pid];
            ids[i] = pid;
            listers[i] = p.listedBy;
            scoreBands[i] = p.currentScoreBand;
            reviewCounts[i] = p.reviewCount;
        }
    }

    function getAverageScoreBandNumerator(bytes32 propertyId) external view returns (uint256) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        uint256 sum = 0;
        for (uint256 i = 0; i < arr.length; i++) sum += arr[i].scoreBand;
        return sum;
    }

    function getTotalReviewCount() external view returns (uint256 total) {
        for (uint256 i = 0; i < _propertyIds.length; i++) {
            total += _reviewsByProperty[_propertyIds[i]].length;
        }
    }

    function getPropertyIdsByRegion(bytes32 regionHash) external view returns (bytes32[] memory) {
        return _propertyIdsByRegion[regionHash];
    }

    function compareScoreBands(bytes32 propertyIdA, bytes32 propertyIdB) external view returns (
        uint8 bandA,
        uint8 bandB,
        int8 difference
    ) {
        bandA = _properties[propertyIdA].currentScoreBand;
        bandB = _properties[propertyIdB].currentScoreBand;
        difference = int8(uint8(bandA)) - int8(uint8(bandB));
    }

    function compareReviewCounts(bytes32 propertyIdA, bytes32 propertyIdB) external view returns (
        uint256 countA,
        uint256 countB
    ) {
        countA = _reviewsByProperty[propertyIdA].length;
        countB = _reviewsByProperty[propertyIdB].length;
    }

    function getTraitValueForStandard(bytes32 propertyId, bytes32 standardTraitKey) external view returns (bytes32) {
        return _traitOf[propertyId][standardTraitKey];
    }

    function getLatticeHashForLatestReview(bytes32 propertyId) external view returns (bytes32) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        if (arr.length == 0) return bytes32(0);
        ReviewRecord storage r = arr[arr.length - 1];
        return _computeLatticeHash(propertyId, r.reviewHash, r.scoreBand, r.blockAnchored);
    }

    function getLatestReview(bytes32 propertyId) external view returns (
        bytes32 reviewHash,
        uint8 scoreBand,
        uint256 blockAnchored,
        address anchoredBy
    ) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        if (arr.length == 0) revert HTL_InvalidIndex();
        ReviewRecord storage r = arr[arr.length - 1];
        return (r.reviewHash, r.scoreBand, r.blockAnchored, r.anchoredBy);
    }

    function getGuideInfo(bytes32 guideId) external view returns (uint256 segmentCount, uint256 createdAt, address createdBy) {
        GuideData storage g = _guides[guideId];
        if (g.createdAt == 0) revert HTL_NotListed();
        return (g.segmentHashes.length, g.createdAt, g.createdBy);
    }

    function getMultipleComparisonSnapshots(bytes32[] calldata leftIds, bytes32[] calldata rightIds) external view returns (bytes32[] memory diffHashes) {
        if (leftIds.length != rightIds.length) revert HTL_BatchLengthMismatch();
        uint256 n = leftIds.length;
        if (n > HTL_MAX_PAGE_SIZE) revert HTL_InvalidIndex();
        diffHashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            if (leftIds[i] == rightIds[i]) continue;
            bytes32 pairKey = keccak256(abi.encodePacked(leftIds[i], rightIds[i]));
            diffHashes[i] = _comparisonSnapshots[pairKey];
        }
    }

    function getPropertyFull(bytes32 propertyId) external view returns (
        bytes32 regionHash,
        address listedBy,
        uint256 blockListed,
        bool frozen,
        uint8 currentScoreBand,
        uint256 reviewCount,
        bytes32 traitBundleHash,
        bytes32[] memory traitKeys,
        bytes32[] memory traitValues
    ) {
        PropertyData storage p = _properties[propertyId];
        if (p.blockListed == 0) revert HTL_NotListed();
        traitKeys = _traitKeysByProperty[propertyId];
        uint256 klen = traitKeys.length;
        traitValues = new bytes32[](klen);
        for (uint256 i = 0; i < klen; i++) traitValues[i] = _traitOf[propertyId][traitKeys[i]];
        return (
            p.regionHash,
            p.listedBy,
            p.blockListed,
            p.frozen,
            p.currentScoreBand,
            p.reviewCount,
            p.traitBundleHash,
            traitKeys,
            traitValues
        );
    }

    function getReviewsFull(bytes32 propertyId) external view returns (
        bytes32[] memory reviewHashes,
        uint8[] memory scoreBands,
        uint256[] memory blocksAnchored,
        address[] memory anchoredBy,
        bytes32[] memory latticeHashes
    ) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        uint256 n = arr.length;
        reviewHashes = new bytes32[](n);
        scoreBands = new uint8[](n);
        blocksAnchored = new uint256[](n);
        anchoredBy = new address[](n);
        latticeHashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ReviewRecord storage r = arr[i];
            reviewHashes[i] = r.reviewHash;
            scoreBands[i] = r.scoreBand;
            blocksAnchored[i] = r.blockAnchored;
            anchoredBy[i] = r.anchoredBy;
            latticeHashes[i] = _computeLatticeHash(propertyId, r.reviewHash, r.scoreBand, r.blockAnchored);
        }
    }

    function getRegionsWithCounts(bytes32[] calldata regionHashes) external view returns (uint256[] memory counts) {
        counts = new uint256[](regionHashes.length);
        for (uint256 i = 0; i < regionHashes.length; i++) counts[i] = _regionPropertyCount[regionHashes[i]];
    }

    function isRegionPausedBatch(bytes32[] calldata regionHashes) external view returns (bool[] memory paused) {
        paused = new bool[](regionHashes.length);
        for (uint256 i = 0; i < regionHashes.length; i++) paused[i] = _regionPaused[regionHashes[i]];
    }

    function getPropertyBlockListed(bytes32 propertyId) external view returns (uint256) {
        return _properties[propertyId].blockListed;
    }

    function getPropertyRegion(bytes32 propertyId) external view returns (bytes32) {
        return _properties[propertyId].regionHash;
    }

    function getPropertyCurrentScoreBand(bytes32 propertyId) external view returns (uint8) {
        return _properties[propertyId].currentScoreBand;
    }

    function getPropertyTraitBundleHash(bytes32 propertyId) external view returns (bytes32) {
        return _properties[propertyId].traitBundleHash;
    }

    function totalGuideSegments() external view returns (uint256 total) {
        for (uint256 i = 0; i < _guideIds.length; i++) {
            total += _guides[_guideIds[i]].segmentHashes.length;
        }
    }

    function getGuideSegmentHashes(bytes32 guideId) external view returns (bytes32[] memory) {
        GuideData storage g = _guides[guideId];
        if (g.createdAt == 0) revert HTL_NotListed();
        return g.segmentHashes;
    }

    function computeExpectedTraitBundleHash(bytes32 propertyId, bytes32[] memory keys, bytes32[] memory values) external view returns (bytes32) {
        return _computeTraitBundleHash(propertyId, keys, values);
    }

    function getBatchPropertyExists(bytes32[] calldata propertyIdsBatch) external view returns (bool[] memory exists) {
        exists = new bool[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            exists[i] = _properties[propertyIdsBatch[i]].blockListed != 0;
        }
    }

    function getBatchPropertyFrozen(bytes32[] calldata propertyIdsBatch) external view returns (bool[] memory frozen) {
        frozen = new bool[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            frozen[i] = _properties[propertyIdsBatch[i]].frozen;
        }
    }

    function getBatchCurrentScoreBands(bytes32[] calldata propertyIdsBatch) external view returns (uint8[] memory bands) {
        bands = new uint8[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            bands[i] = _properties[propertyIdsBatch[i]].currentScoreBand;
        }
    }

    function getBatchReviewCounts(bytes32[] calldata propertyIdsBatch) external view returns (uint256[] memory counts) {
        counts = new uint256[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            counts[i] = _reviewsByProperty[propertyIdsBatch[i]].length;
        }
    }

    function getTopScoreBandProperties(bytes32 regionHash, uint256 limit) external view returns (bytes32[] memory ids, uint8[] memory bands) {
        bytes32[] storage regionIds = _propertyIdsByRegion[regionHash];
        uint256 n = regionIds.length;
        if (n == 0) {
            ids = new bytes32[](0);
            bands = new uint8[](0);
            return (ids, bands);
        }
        if (limit > n) limit = n;
        ids = new bytes32[](limit);
        bands = new uint8[](limit);
        uint256[] memory indices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) indices[i] = i;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                uint8 bandI = _properties[regionIds[indices[i]]].currentScoreBand;
                uint8 bandJ = _properties[regionIds[indices[j]]].currentScoreBand;
                if (bandJ > bandI) {
                    uint256 t = indices[i];
                    indices[i] = indices[j];
                    indices[j] = t;
                }
            }
        }
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = regionIds[indices[i]];
            bands[i] = _properties[ids[i]].currentScoreBand;
        }
    }

    function getPropertiesWithMinReviews(bytes32 regionHash, uint256 minReviews) external view returns (bytes32[] memory ids) {
        bytes32[] storage regionIds = _propertyIdsByRegion[regionHash];
        uint256 count = 0;
        for (uint256 i = 0; i < regionIds.length; i++) {
            if (_reviewsByProperty[regionIds[i]].length >= minReviews) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < regionIds.length; i++) {
            if (_reviewsByProperty[regionIds[i]].length >= minReviews) {
                ids[j] = regionIds[i];
                j++;
            }
        }
    }

    function getLatticeSalts() external pure returns (bytes32 latticeSalt, bytes32 guideAnchor) {
        return (HTL_LATTICE_SALT, HTL_GUIDE_ANCHOR);
    }

    function getStandardTraitKeys() external pure returns (
        bytes32 amenityKey,
        bytes32 priceTierKey,
        bytes32 starRatingKey,
        bytes32 chainIdKey,
        bytes32 localeKey,
        bytes32 aiSummaryKey
    ) {
        return (
            HTL_TRAIT_AMENITY,
            HTL_TRAIT_PRICE_TIER,
            HTL_TRAIT_STAR_RATING,
            HTL_TRAIT_CHAIN_ID,
            HTL_TRAIT_LOCALE,
            HTL_TRAIT_AI_SUMMARY
        );
    }

    // -------------------------------------------------------------------------
    // PURE HELPERS — LATTICE & PAIR (OFF-CHAIN / FRONTEND)
    // -------------------------------------------------------------------------

    function computeLatticeHash(bytes32 propertyId, bytes32 reviewHash, uint8 scoreBand, uint256 atBlock) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(HTL_LATTICE_SALT, propertyId, reviewHash, scoreBand, atBlock));
    }

    function computePairKey(bytes32 leftId, bytes32 rightId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(leftId, rightId));
    }

    function computeTraitBundleHashFromPairs(bytes32 propertyId, bytes32[] calldata keys, bytes32[] calldata values) external pure returns (bytes32) {
        if (keys.length != values.length) revert HTL_BatchLengthMismatch();
        bytes32 h = HTL_LATTICE_SALT;
        for (uint256 i = 0; i < keys.length; i++) {
            h = keccak256(abi.encodePacked(h, propertyId, keys[i], values[i]));
        }
        return h;
    }

    // -------------------------------------------------------------------------
    // EXTENDED BATCH VIEWS — AI REVIEW CHECKER BULK
    // -------------------------------------------------------------------------

    function getAverageScoreBandsBatch(bytes32[] calldata propertyIdsBatch) external view returns (uint256[] memory numerators, uint256[] memory denominators) {
        uint256 n = propertyIdsBatch.length;
        if (n > HTL_MAX_PAGE_SIZE) revert HTL_InvalidIndex();
        numerators = new uint256[](n);
        denominators = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ReviewRecord[] storage arr = _reviewsByProperty[propertyIdsBatch[i]];
            uint256 len = arr.length;
            denominators[i] = len;
            if (len == 0) continue;
            uint256 sum = 0;
            for (uint256 j = 0; j < len; j++) sum += arr[j].scoreBand;
            numerators[i] = sum;
        }
    }

    function getMedianScoreBandsBatch(bytes32[] calldata propertyIdsBatch) external view returns (uint8[] memory medians) {
        uint256 n = propertyIdsBatch.length;
        if (n > HTL_MAX_PAGE_SIZE) revert HTL_InvalidIndex();
        medians = new uint8[](n);
        for (uint256 idx = 0; idx < n; idx++) {
            ReviewRecord[] storage arr = _reviewsByProperty[propertyIdsBatch[idx]];
            uint256 len = arr.length;
            if (len == 0) {
                medians[idx] = 0;
                continue;
            }
            uint256[] memory bands = new uint256[](len);
            for (uint256 i = 0; i < len; i++) bands[i] = arr[i].scoreBand;
            for (uint256 i = 0; i < len - 1; i++) {
                for (uint256 j = i + 1; j < len; j++) {
                    if (bands[j] < bands[i]) {
                        uint256 t = bands[i];
                        bands[i] = bands[j];
                        bands[j] = t;
                    }
                }
            }
            if (len % 2 == 1) medians[idx] = uint8(bands[len / 2]);
            else medians[idx] = uint8((bands[len / 2 - 1] + bands[len / 2]) / 2);
        }
    }

    function getScoreBandDistributionsBatch(bytes32[] calldata propertyIdsBatch) external view returns (uint256[][] memory distributions) {
        uint256 n = propertyIdsBatch.length;
        if (n > HTL_MAX_PAGE_SIZE) revert HTL_InvalidIndex();
        distributions = new uint256[][](n);
        for (uint256 idx = 0; idx < n; idx++) {
            uint256[] memory counts = new uint256[](HTL_SCORE_BAND_MAX + 1);
            ReviewRecord[] storage arr = _reviewsByProperty[propertyIdsBatch[idx]];
            for (uint256 i = 0; i < arr.length; i++) {
                uint8 b = arr[i].scoreBand;
                if (b <= HTL_SCORE_BAND_MAX) counts[b]++;
            }
            distributions[idx] = counts;
        }
    }

    function getLatestReviewsBatch(bytes32[] calldata propertyIdsBatch) external view returns (
        bytes32[] memory reviewHashes,
        uint8[] memory scoreBands,
        uint256[] memory blocksAnchored,
        address[] memory anchoredBy
    ) {
        uint256 n = propertyIdsBatch.length;
        if (n > HTL_MAX_PAGE_SIZE) revert HTL_InvalidIndex();
        reviewHashes = new bytes32[](n);
        scoreBands = new uint8[](n);
        blocksAnchored = new uint256[](n);
        anchoredBy = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            ReviewRecord[] storage arr = _reviewsByProperty[propertyIdsBatch[i]];
            if (arr.length == 0) {
                reviewHashes[i] = bytes32(0);
                scoreBands[i] = 0;
                blocksAnchored[i] = 0;
                anchoredBy[i] = address(0);
            } else {
                ReviewRecord storage r = arr[arr.length - 1];
                reviewHashes[i] = r.reviewHash;
                scoreBands[i] = r.scoreBand;
                blocksAnchored[i] = r.blockAnchored;
                anchoredBy[i] = r.anchoredBy;
            }
        }
    }

    function getLatticeHashesForLatestReviewsBatch(bytes32[] calldata propertyIdsBatch) external view returns (bytes32[] memory latticeHashes) {
        uint256 n = propertyIdsBatch.length;
        if (n > HTL_MAX_PAGE_SIZE) revert HTL_InvalidIndex();
        latticeHashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ReviewRecord[] storage arr = _reviewsByProperty[propertyIdsBatch[i]];
            if (arr.length == 0) latticeHashes[i] = bytes32(0);
            else {
                ReviewRecord storage r = arr[arr.length - 1];
                latticeHashes[i] = _computeLatticeHash(propertyIdsBatch[i], r.reviewHash, r.scoreBand, r.blockAnchored);
            }
        }
    }

    function getPropertySummariesByRegion(bytes32 regionHash) external view returns (
        bytes32[] memory ids,
        address[] memory listers,
        uint256[] memory blocksListed,
        bool[] memory frozenFlags,
        uint8[] memory scoreBands,
        uint256[] memory reviewCounts
    ) {
        bytes32[] storage regionIds = _propertyIdsByRegion[regionHash];
        uint256 n = regionIds.length;
        ids = new bytes32[](n);
        listers = new address[](n);
        blocksListed = new uint256[](n);
        frozenFlags = new bool[](n);
        scoreBands = new uint8[](n);
        reviewCounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            PropertyData storage p = _properties[regionIds[i]];
            ids[i] = regionIds[i];
            listers[i] = p.listedBy;
            blocksListed[i] = p.blockListed;
            frozenFlags[i] = p.frozen;
            scoreBands[i] = p.currentScoreBand;
            reviewCounts[i] = p.reviewCount;
        }
    }

    function getGuideIdsByCreator(address creator) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _guideIds.length; i++) {
            if (_guides[_guideIds[i]].createdBy == creator) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _guideIds.length; i++) {
            if (_guides[_guideIds[i]].createdBy == creator) {
                ids[j] = _guideIds[i];
                j++;
            }
        }
    }

    function getGuidesSliceFull(uint256 offset, uint256 limit) external view returns (
        bytes32[] memory guideIds,
        uint256[] memory segmentCounts,
        uint256[] memory createdAts,
        address[] memory createdBys
    ) {
        uint256 total = _guideIds.length;
        if (offset >= total) {
            guideIds = new bytes32[](0);
            segmentCounts = new uint256[](0);
            createdAts = new uint256[](0);
            createdBys = new address[](0);
            return (guideIds, segmentCounts, createdAts, createdBys);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        guideIds = new bytes32[](n);
        segmentCounts = new uint256[](n);
        createdAts = new uint256[](n);
        createdBys = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 gid = _guideIds[offset + i];
            GuideData storage g = _guides[gid];
            guideIds[i] = gid;
            segmentCounts[i] = g.segmentHashes.length;
            createdAts[i] = g.createdAt;
            createdBys[i] = g.createdBy;
        }
    }

    function getPropertyIdsPaginated(uint256 page, uint256 pageSize) external view returns (bytes32[] memory ids, uint256 total) {
        total = _propertyIds.length;
        uint256 offset = page * pageSize;
        if (offset >= total) return (new bytes32[](0), total);
        uint256 end = offset + pageSize;
        if (end > total) end = total;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _propertyIds[offset + i];
    }

    function getReviewCountsBatch(bytes32[] calldata propertyIdsBatch) external view returns (uint256[] memory counts) {
        counts = new uint256[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            counts[i] = _reviewsByProperty[propertyIdsBatch[i]].length;
        }
    }

    function getTraitBundleHashesBatch(bytes32[] calldata propertyIdsBatch) external view returns (bytes32[] memory hashes) {
        hashes = new bytes32[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            hashes[i] = _properties[propertyIdsBatch[i]].traitBundleHash;
        }
    }

    function getRegionHashesBatch(bytes32[] calldata propertyIdsBatch) external view returns (bytes32[] memory regionHashes) {
        regionHashes = new bytes32[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            regionHashes[i] = _properties[propertyIdsBatch[i]].regionHash;
        }
    }

    function getListedByBatch(bytes32[] calldata propertyIdsBatch) external view returns (address[] memory listers) {
        listers = new address[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            listers[i] = _properties[propertyIdsBatch[i]].listedBy;
        }
    }

    function getBlockListedBatch(bytes32[] calldata propertyIdsBatch) external view returns (uint256[] memory blocks) {
        blocks = new uint256[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            blocks[i] = _properties[propertyIdsBatch[i]].blockListed;
        }
    }

    function supportsComparisonMatrix(bytes32[] calldata propertyIdsBatch) external view returns (bool[] memory hasAnyComparison) {
        hasAnyComparison = new bool[](propertyIdsBatch.length);
        for (uint256 i = 0; i < propertyIdsBatch.length; i++) {
            bytes32 pid = propertyIdsBatch[i];
            bool found = false;
            for (uint256 j = 0; j < _propertyIds.length && !found; j++) {
                bytes32 other = _propertyIds[j];
                if (other == pid) continue;
                bytes32 pairKey = keccak256(abi.encodePacked(pid, other));
                if (_comparisonSnapshots[pairKey] != bytes32(0)) found = true;
            }
            hasAnyComparison[i] = found;
        }
    }

    // -------------------------------------------------------------------------
    // ADDITIONAL CONVENIENCE VIEWS — HOTEL COMPARISON & AI GUIDE
    // -------------------------------------------------------------------------

    function getPropertyCountInRegion(bytes32 regionHash) external view returns (uint256) {
        return _propertyIdsByRegion[regionHash].length;
    }

    function getFirstNPropertyIds(uint256 n) external view returns (bytes32[] memory ids) {
        uint256 total = _propertyIds.length;
        if (n > total) n = total;
        if (n == 0) return new bytes32[](0);
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = _propertyIds[i];
    }

    function getLastNPropertyIds(uint256 n) external view returns (bytes32[] memory ids) {
        uint256 total = _propertyIds.length;
        if (n > total) n = total;
        if (n == 0) return new bytes32[](0);
        ids = new bytes32[](n);
        uint256 start = total - n;
        for (uint256 i = 0; i < n; i++) ids[i] = _propertyIds[start + i];
    }

    function getPropertiesListedAfterBlock(uint256 fromBlock) external view returns (bytes32[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < _propertyIds.length; i++) {
            if (_properties[_propertyIds[i]].blockListed >= fromBlock) count++;
        }
        ids = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _propertyIds.length; i++) {
            if (_properties[_propertyIds[i]].blockListed >= fromBlock) {
                ids[j] = _propertyIds[i];
                j++;
            }
        }
    }

    function getReviewsAnchoredAfterBlock(bytes32 propertyId, uint256 fromBlock) external view returns (
        uint256[] memory indices,
        bytes32[] memory reviewHashes,
        uint8[] memory scoreBands,
        uint256[] memory blocksAnchored
    ) {
        ReviewRecord[] storage arr = _reviewsByProperty[propertyId];
        uint256 count = 0;
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].blockAnchored >= fromBlock) count++;
        }
        indices = new uint256[](count);
        reviewHashes = new bytes32[](count);
        scoreBands = new uint8[](count);
        blocksAnchored = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].blockAnchored >= fromBlock) {
                indices[j] = i;
                reviewHashes[j] = arr[i].reviewHash;
                scoreBands[j] = arr[i].scoreBand;
                blocksAnchored[j] = arr[i].blockAnchored;
                j++;
            }
        }
    }

    function getTraitKeysCount(bytes32 propertyId) external view returns (uint256) {
        return _traitKeysByProperty[propertyId].length;
    }

    function getTraitValue(bytes32 propertyId, bytes32 key) external view returns (bytes32) {
        return _traitOf[propertyId][key];
    }

    function getMultipleTraits(bytes32 propertyId, bytes32 key1, bytes32 key2, bytes32 key3) external view returns (bytes32 v1, bytes32 v2, bytes32 v3) {
        return (_traitOf[propertyId][key1], _traitOf[propertyId][key2], _traitOf[propertyId][key3]);
    }

    function getGuideCreatedAt(bytes32 guideId) external view returns (uint256) {
        return _guides[guideId].createdAt;
    }

    function getGuideCreatedBy(bytes32 guideId) external view returns (address) {
        return _guides[guideId].createdBy;
    }

    function getGuideSegmentCount(bytes32 guideId) external view returns (uint256) {
        return _guides[guideId].segmentHashes.length;
    }

    function getTotalProperties() external view returns (uint256) {
        return _propertyIds.length;
    }

    function getTotalGuides() external view returns (uint256) {
        return _guideIds.length;
    }

    function getCurationPaused() external view returns (bool) {
        return curationPaused;
    }

    function getTreasuryAddress() external view returns (address) {
        return treasury;
    }

    function getDeployBlock() external view returns (uint256) {
        return deployBlock;
    }

    function getCuratorAddress() external view returns (address) {
        return curator;
    }

    function getReviewOracleAddress() external view returns (address) {
        return reviewOracle;
    }

    function getTreasuryKeeperAddress() external view returns (address) {
        return treasuryKeeper;
    }

    function getMaxProperties() external pure returns (uint256) {
        return HTL_MAX_PROPERTIES;
    }

    function getMaxReviewsPerProperty() external pure returns (uint256) {
        return HTL_MAX_REVIEWS_PER_PROPERTY;
    }

    function getMaxGuideSegments() external pure returns (uint256) {
        return HTL_MAX_GUIDE_SEGMENTS;
    }

    function getScoreBandMax() external pure returns (uint256) {
        return HTL_SCORE_BAND_MAX;
    }

    function getMaxPageSize() external pure returns (uint256) {
        return HTL_MAX_PAGE_SIZE;
    }
