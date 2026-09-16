// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts@1.3.0/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts@1.3.0/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {HousePicker} from "../src/HousePicker.sol";

contract HousePickerTest is Test {
    uint96 internal constant BASE_FEE = 0.1 ether;
    uint96 internal constant GAS_PRICE = 1 gwei;
    int256 internal constant WEI_PER_UNIT_LINK = 0.004 ether;

    VRFCoordinatorV2_5Mock internal coordinator;
    HousePicker internal housePicker;
    uint256 internal subId;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event DiceRolled(uint256 indexed requestId, address indexed roller);
    event DiceLanded(uint256 indexed requestId, uint256 indexed result);

    function setUp() public {
        coordinator = new VRFCoordinatorV2_5Mock(BASE_FEE, GAS_PRICE, WEI_PER_UNIT_LINK);
        subId = coordinator.createSubscription();
        // Each fulfillment costs ~25 LINK at these mock rates; fund well clear of that.
        coordinator.fundSubscription(subId, 1000 ether);

        housePicker = new HousePicker(subId);
        // The constructor hardcodes the live Sepolia coordinator, so repoint the
        // consumer at the mock. This test contract is the owner (it deployed it).
        housePicker.setCoordinator(address(coordinator));
        coordinator.addConsumer(subId, address(housePicker));
    }

    /// @dev Rolls for `player` and fulfills with an exact random word.
    function _rollAndFulfill(address player, uint256 randomWord) internal returns (uint256 requestId) {
        requestId = _roll(player);
        _fulfill(requestId, randomWord);
    }

    function _roll(address player) internal returns (uint256 requestId) {
        vm.prank(player);
        requestId = housePicker.rollDice();
    }

    function _fulfill(uint256 requestId, uint256 randomWord) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        coordinator.fulfillRandomWordsWithOverride(requestId, address(housePicker), words);
    }

    function _expectedHouse(uint256 randomWord) internal pure returns (string memory) {
        uint256 id = randomWord % 4;
        if (id == 0) return "Gryffindor";
        if (id == 1) return "Hufflepuff";
        if (id == 2) return "Slytherin";
        return "Ravenclaw";
    }

    // --- Setup sanity -------------------------------------------------------

    function test_setUp_wiresConsumerToMockCoordinator() public view {
        assertEq(address(housePicker.s_vrfCoordinator()), address(coordinator));
        assertEq(housePicker.s_subscriptionId(), subId);
        assertTrue(coordinator.consumerIsAdded(subId, address(housePicker)));
    }

    // --- House mapping ------------------------------------------------------

    function test_house_mapsAllFourHouses() public {
        address[4] memory players = [makeAddr("p0"), makeAddr("p1"), makeAddr("p2"), makeAddr("p3")];
        string[4] memory expected = ["Gryffindor", "Hufflepuff", "Slytherin", "Ravenclaw"];

        for (uint256 i = 0; i < 4; i++) {
            // % 4 == i, so each player lands in a different house.
            _rollAndFulfill(players[i], 400 + i);
            assertEq(housePicker.house(players[i]), expected[i]);
        }
    }

    /// @dev Regression: house id 0 used to collide with the "never rolled"
    /// sentinel, so a Gryffindor roller could never read their own house.
    function test_house_gryffindorIsReadable() public {
        _rollAndFulfill(alice, 400); // 400 % 4 == 0
        assertEq(housePicker.house(alice), "Gryffindor");
    }

    /// @dev Regression: the same collision let a Gryffindor roller past the
    /// `s_results[msg.sender] == 0` guard and roll a second time.
    function test_rollDice_gryffindorRollerCannotRollAgain() public {
        _rollAndFulfill(alice, 400);

        vm.prank(alice);
        vm.expectRevert(bytes("Already rolled"));
        housePicker.rollDice();
    }

    /// @dev The core invariant the fix buys us: whatever the VRF returns,
    /// `house()` resolves to one of the four houses and never reverts.
    function testFuzz_house_alwaysResolvesAfterFulfillment(uint256 randomWord) public {
        _rollAndFulfill(alice, randomWord);
        assertEq(housePicker.house(alice), _expectedHouse(randomWord));
    }

    // --- Guards -------------------------------------------------------------

    function test_house_revertsIfNeverRolled() public {
        vm.expectRevert(bytes("Dice not rolled"));
        housePicker.house(bob);
    }

    function test_house_revertsWhileRollInProgress() public {
        _roll(alice); // requested, not yet fulfilled

        vm.expectRevert(bytes("Roll in progress"));
        housePicker.house(alice);
    }

    function test_rollDice_revertsWhileRollInProgress() public {
        _roll(alice);

        vm.prank(alice);
        vm.expectRevert(bytes("Already rolled"));
        housePicker.rollDice();
    }

    function test_rawFulfillRandomWords_onlyCoordinator() public {
        uint256 requestId = _roll(alice);
        uint256[] memory words = new uint256[](1);
        words[0] = 7;

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(VRFConsumerBaseV2Plus.OnlyCoordinatorCanFulfill.selector, bob, address(coordinator))
        );
        housePicker.rawFulfillRandomWords(requestId, words);
    }

    // --- Events -------------------------------------------------------------

    function test_rollDice_emitsDiceRolled() public {
        vm.expectEmit(false, true, false, false, address(housePicker));
        emit DiceRolled(0, alice);

        vm.prank(alice);
        housePicker.rollDice();
    }

    function test_fulfill_emitsDiceLandedWithOneBasedId() public {
        uint256 requestId = _roll(alice);

        // 400 % 4 + 1 == 1 (Gryffindor); pre-fix this emitted 0.
        vm.expectEmit(true, true, false, false, address(housePicker));
        emit DiceLanded(requestId, 1);
        _fulfill(requestId, 400);
    }

    // --- Callback gas -------------------------------------------------------

    /// @dev `callbackGasLimit` is hardcoded at 40k with no setter. If the callback
    /// ever exceeds it the coordinator's low-level call fails silently, stranding
    /// the player on ROLL_IN_PROGRESS forever, so keep an eye on the headroom.
    function test_fulfillment_fitsInCallbackGasLimit() public {
        uint256 requestId = _roll(alice);
        uint256[] memory words = new uint256[](1);
        words[0] = 400;

        // Fulfillment is a separate transaction on-chain, so the slots the
        // callback touches are cold. Undo the warming done by _roll.
        vm.cool(address(housePicker));

        vm.prank(address(coordinator));
        uint256 gasBefore = gasleft();
        housePicker.rawFulfillRandomWords(requestId, words);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("callback gas used (cold slots)", gasUsed);
        emit log_named_uint("callbackGasLimit             ", housePicker.callbackGasLimit());
        assertLt(gasUsed, housePicker.callbackGasLimit());
    }

    // --- Independence between players --------------------------------------

    function test_house_isPerPlayer() public {
        _rollAndFulfill(alice, 400); // Gryffindor
        _rollAndFulfill(bob, 402); // Slytherin

        assertEq(housePicker.house(alice), "Gryffindor");
        assertEq(housePicker.house(bob), "Slytherin");
    }
}
