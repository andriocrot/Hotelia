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
