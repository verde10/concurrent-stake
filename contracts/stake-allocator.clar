;; stake-allocator.clar
;; This contract manages concurrent stake allocation and reward distribution on the Stacks blockchain.
;; The contract provides a flexible staking mechanism with dynamic reward calculations,
;; allowing users to deposit, track, and withdraw stakes while earning rewards proportional to their contribution.
;; It implements secure, transparent stake management with configurable reward parameters.

;; -----------------
;; -----------------
;; Error Constants
;; -----------------

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-STAKE (err u101))
(define-constant ERR-STAKE-LOCKED (err u102))
(define-constant ERR-INVALID-STAKE-AMOUNT (err u103))
(define-constant ERR-REWARD-CALCULATION-FAILED (err u104))
(define-constant ERR-PLATFORM-FEE-TOO-HIGH (err u105))
(define-constant ERR-INSUFFICIENT-BALANCE (err u106))
(define-constant ERR-STAKE-NOT-FOUND (err u107))

;; -----------------
;; Data Storage
;; -----------------

;; Admin address to manage platform functions
(define-data-var contract-admin principal tx-sender)

;; Platform fee percentage (in basis points, e.g. 250 = 2.5%)
(define-data-var platform-fee-bps uint u250)

;; Total staked amount
(define-data-var total-staked-amount uint u0)

;; Stake epoch duration (in blocks)
(define-data-var stake-epoch-duration uint u144)  ;; Approximately 1 day

;; Base reward rate (in basis points)
(define-data-var base-reward-rate uint u500)  ;; 5% base reward

;; Stake Records
(define-map stake-records
  principal
  {
    amount: uint,           ;; Current staked amount
    start-block: uint,      ;; Block when stake was initiated
    last-claim-block: uint, ;; Last block rewards were claimed
    locked-until: uint      ;; Block until which stake is locked
  }
)

;; -----------------
;; Private Functions
;; -----------------

;; Calculate platform fee amount
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-bps)) u10000)
)

;; Calculate stake rewards based on duration and rate
(define-private (calculate-stake-rewards (stake-amount uint) (blocks-staked uint))
  (let (
    (base-rate (var-get base-reward-rate))
    (reward-amount (/ (* stake-amount base-rate blocks-staked) u10000))
  )
    reward-amount
  )
)

;; Check if a stake is currently locked
(define-private (is-stake-locked (locked-until uint))
  (>= block-height locked-until)
)

;; Check if the caller is the contract admin
(define-private (is-contract-admin)
  (is-eq tx-sender (var-get contract-admin))
)

;; -----------------
;; Read-only Functions
;; -----------------

;; Get stake record for a principal
(define-read-only (get-stake-record (staker principal))
  (map-get? stake-records staker)
)

;; Get total staked amount
(define-read-only (get-total-staked-amount)
  (var-get total-staked-amount)
)

;; Calculate potential rewards for a stake
(define-read-only (get-potential-rewards (staker principal))
  (match (map-get? stake-records staker)
    stake-data 
      (let (
        (blocks-staked (- block-height (get start-block stake-data)))
        (rewards (calculate-stake-rewards (get amount stake-data) blocks-staked))
      )
        (some rewards)
      )
    none
  )
)

;; -----------------
;; Public Functions
;; -----------------

;; Deposit stake tokens
(define-public (deposit-stake (amount uint) (lock-duration uint))
  (let (
    (current-stake (default-to {amount: u0, start-block: block-height, last-claim-block: block-height, locked-until: u0} (map-get? stake-records tx-sender)))
    (total-amount (+ (get amount current-stake) amount))
    (locked-until (+ block-height lock-duration))
  )
    ;; Validate stake amount
    (asserts! (> amount u0) ERR-INVALID-STAKE-AMOUNT)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update stake record
    (map-set stake-records
      tx-sender
      {
        amount: total-amount,
        start-block: block-height,
        last-claim-block: block-height,
        locked-until: locked-until
      }
    )
    
    ;; Update total staked amount
    (var-set total-staked-amount (+ (var-get total-staked-amount) amount))
    
    (ok total-amount)
  )
)

;; Withdraw staked tokens
(define-public (withdraw-stake (amount uint))
  (let (
    (stake-data (unwrap! (map-get? stake-records tx-sender) ERR-STAKE-NOT-FOUND))
  )
    ;; Ensure stake is unlocked
    (asserts! (is-stake-locked (get locked-until stake-data)) ERR-STAKE-LOCKED)
    
    ;; Ensure sufficient stake
    (asserts! (>= (get amount stake-data) amount) ERR-INSUFFICIENT-STAKE)
    
    ;; Transfer STX back to user
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    
    ;; Update stake record
    (map-set stake-records
      tx-sender
      {
        amount: (- (get amount stake-data) amount),
        start-block: (get start-block stake-data),
        last-claim-block: block-height,
        locked-until: (get locked-until stake-data)
      }
    )
    
    ;; Update total staked amount
    (var-set total-staked-amount (- (var-get total-staked-amount) amount))
    
    (ok amount)
  )
)

;; Claim stake rewards
(define-public (claim-rewards)
  (let (
    (stake-data (unwrap! (map-get? stake-records tx-sender) ERR-STAKE-NOT-FOUND))
    (blocks-staked (- block-height (get start-block stake-data)))
    (rewards (calculate-stake-rewards (get amount stake-data) blocks-staked))
    (platform-fee (calculate-platform-fee rewards))
    (net-rewards (- rewards platform-fee))
  )
    ;; Ensure rewards are claimable
    (asserts! (> rewards u0) ERR-REWARD-CALCULATION-FAILED)
    
    ;; Transfer rewards to user
    (try! (as-contract (stx-transfer? net-rewards tx-sender tx-sender)))
    (try! (as-contract (stx-transfer? platform-fee tx-sender (var-get contract-admin))))
    
    ;; Update stake record
    (map-set stake-records
      tx-sender
      {
        amount: (get amount stake-data),
        start-block: (get start-block stake-data),
        last-claim-block: block-height,
        locked-until: (get locked-until stake-data)
      }
    )
    
    (ok net-rewards)
  )
)

;; Update platform fee (admin only)
(define-public (set-platform-fee (new-fee-bps uint))
  (begin
    ;; Verify caller is admin
    (asserts! (is-contract-admin) ERR-NOT-AUTHORIZED)
    
    ;; Ensure fee is reasonable (max 10%)
    (asserts! (<= new-fee-bps u1000) ERR-PLATFORM-FEE-TOO-HIGH)
    
    ;; Update fee
    (var-set platform-fee-bps new-fee-bps)
    
    (ok true)
  )
)

;; Transfer contract admin role (admin only)
(define-public (set-contract-admin (new-admin principal))
  (begin
    ;; Verify caller is current admin
    (asserts! (is-contract-admin) ERR-NOT-AUTHORIZED)
    
    ;; Update admin
    (var-set contract-admin new-admin)
    
    (ok true)
  )
)