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
