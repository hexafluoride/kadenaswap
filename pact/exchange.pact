(enforce-pact-version "3.7")

(namespace (read-msg 'ns))

(module exchange GOVERNANCE

  @model
  [

   ;; prop-pairs-write-guard
   ;; guard is never enforced, but this allows enumeration of
   ;; every write, and forward security for newly-added functions.
   (property
    (forall (k:string)
     (when (row-written pairs k)
       (row-enforced pairs 'guard k)))
    { 'except:
      [ create-pair      ;; unguarded (insert semantics)
        add-liquidity    ;; prop-increase-liquidity
        remove-liquidity ;; prop-decrease-liquidity
        swap-exact-in    ;; prop-increase-liquidity
        swap-exact-out   ;; prop-increase-liquidity
        swap             ;; prop-increase-liquidity
        swap-pair        ;; PRIVATE
        swap-alloc       ;; PRIVATE
        update-reserves  ;; PRIVATE
      ] } )


   ;;prop-increase-liquidity
   ;;computes constant-product variance
   (defproperty increase-liquidity
     ( amount0:decimal
       amount1:decimal )
    (forall (k:string)
     (when (row-written pairs k)
      (<= (* (at 'reserve (at 'leg0 (read k)))
             (at 'reserve (at 'leg1 (read k))))
          (* (+ amount0
               (at 'reserve (at 'leg0 (read k))))
             (+ amount1
               (at 'reserve (at 'leg1 (read k)))))))))

   ;;prop-decrease-liquidity
   ;;computes constant-product variance
   (defproperty decrease-liquidity
     ( amount0:decimal
       amount1:decimal )
    (forall (k:string)
     (when (row-written pairs k)
      (>= (* (at 'reserve (at 'leg0 (read k)))
             (at 'reserve (at 'leg1 (read k))))
          (* (+ amount0
               (at 'reserve (at 'leg0 (read k))))
             (+ amount1
               (at 'reserve (at 'leg1 (read k)))))))))

  ]

  (defcap GOVERNANCE ()
    (enforce-guard (keyset-ref-guard 'swap-ns-admin)))

  (defcap CREATE_PAIR
    ( token0:module{fungible-v2}
      token1:module{fungible-v2}
      key:string
      account:string )
    " Pair-created event for TOKEN0 and TOKEN1 pairs with KEY liquidity token \
    \ and ACCOUNT on leg tokens."
    @event
    ;; dupes checked in 'get-pair-create'
    true)

  (defcap ISSUING ()
    "Private defcap for issuing operations."
    true)

  (defcap SWAPPING ()
    "Private defcap for swapping operations."
    true)

  (defcap SWAP
    ( sender:string
      receiver:string
      in:decimal
      token-in:module{fungible-v2}
      out:decimal
      token-out:module{fungible-v2}
    )
    " Swap event debiting IN of TOKEN-IN from SENDER \
    \ for OUT of TOKEN-OUT on RECEIVER."
    @event
    true
  )

  (defcap DEBUG (message:string)
    @event
    true)

  (defcap UPDATING ()
    "Private defcap for updating operations."
    true)

  (defcap UPDATE
    ( pair:string
      reserve0:decimal
      reserve1:decimal
    )
    "Event notifying reserves update for PAIR to RESERVE0 and RESERVE1."
    @event
    true
  )

  (defcap OBSERVING ()
    "Private defcap for recording observations."
    true)

  (defconst EPOCH_ZERO:time (parse-time "%s" "0"))

  (defschema leg
    token:module{fungible-v2}
    reserve:decimal
    )

  (defschema pair
    leg0:object{leg}
    leg1:object{leg}
    account:string
    guard:guard
    )

  (deftable pairs:{pair})

  (defschema oracle
    pair-key:string
    observation-capacity:integer
    observations-made:integer
    cumulative-price0:decimal
    cumulative-price1:decimal
    last-observed:time)

  (deftable oracles:{oracle})

  (defschema observation
    timestamp:time
    price0:decimal
    price1:decimal)

  (deftable observations:{observation})

  (defconst MINIMUM_LIQUIDITY 0.1)

  (defconst LOCK_ACCOUNT "lock")

  (defun init ()
    (tokens.init-issuer (create-module-guard "issuance"))
  )

  (defun get-oracle:object{oracle}
    ( pair-key:string )
    (read oracles pair-key)
  )

  (defun try-get-observation:object{observation}
    ( oracle:object{oracle}
      relative-index:integer
    )
    (read observations (get-observation-key oracle relative-index))
  )

  (defun dump-observations:[object{observation}]
    ( pair-key:string )
    (let ((oracle (read oracles pair-key)))
      (map
        (compose (compose-observation-key pair-key) (read observations))
        (enumerate 0 (- (at 'observation-capacity oracle) 1)))
    )
  )

  (defun compose-observation-key:string
    ( pair-key:string
      absolute-index:integer
    )
    (format "{}@{}" [pair-key absolute-index])
  )

  (defun get-observation-key:string
    ( pair-oracle:object{oracle}
      relative-index:integer
    )
    (bind pair-oracle
      { 'pair-key := pair-key
      , 'observations-made := head
      , 'observation-capacity := capacity }
      (compose-observation-key pair-key (mod (+ head relative-index) capacity)))
  )

  (defun extend-single
    ( pair-key:string
      nth-slot:integer
    )
    (insert observations (compose-observation-key pair-key nth-slot)
      { 'timestamp: EPOCH_ZERO
      , 'price0: 0.0
      , 'price1: 0.0 })
  )

  (defun extend-oracle
    ( pair-key:string
      new-entries:integer
    )
    (with-read oracles pair-key
      { 'observations-made := head-absolute
      , 'observation-capacity := old-capacity }
      (enforce (> new-entries 0) "Must add nonnegative number of observation slots.")
      (map
        (compose (+ old-capacity) (extend-single pair-key))
        (enumerate 0 (- new-entries 1)))
      (update oracles pair-key
        { 'observation-capacity: (+ old-capacity new-entries)
        , 'observations-made: (mod head-absolute old-capacity)}))
  )

  (defun linear-short-circuit-query:object
    ( a:object
      b:integer)
    (if (at 'found a) a
      (let*
        ( (oracle (at 'oracle a))
          (query-time (at 'time a))
          (previous-observation (at 'current a))
          (next-observation (read observations (get-observation-key oracle b)))
          (found (observation-in-range previous-observation next-observation query-time))
        )
        { 'found: found
        , 'current: next-observation
        , 'prev: previous-observation
        , 'oracle: oracle
        , 'time: query-time}))
  )

  (defun linear-search-for-observation:object{observation}
    ( pair-key:string
      target:time
    )
    (let*
      ( (oracle (read oracles pair-key))
        (observation-capacity (at 'observation-capacity oracle))
        (result (fold
          (linear-short-circuit-query)
          { 'found: false, 'time: target, 'oracle: oracle, 'current: {} }
          (enumerate (- observation-capacity 1) 0)))
      )
      (if (at 'found result)
        { 'left-observation: (at 'prev result), 'right-observation: (at 'current result) }
        {})
    )
  )

  (defun short-circuit-query:object
    ( a:object
      b:integer)
    (if (at 'found a) a
      (if (at 'failed a) a
        (bind a
          { 'oracle := oracle
          , 'time := query-time
          , 'left-index := left-index
          , 'right-index := right-index
          , 'left-observation := left-observation
          , 'right-observation := right-observation }
          (let*
            ( (middle-index (/ (+ left-index right-index) 2))
              (middle-observation (read observations (get-observation-key oracle middle-index)))
              (go-left (observation-in-range left-observation middle-observation query-time))
              (go-right (observation-in-range middle-observation right-observation query-time))
            )
            (with-capability (DEBUG (format "left {} {} middle {} {} right {} {} query {} go left {} go right {}" [left-index (at 'timestamp left-observation) middle-index (at 'timestamp middle-observation) right-index (at 'timestamp right-observation) query-time go-left go-right]))
              (if (not (or go-left go-right)) { 'found: false, 'failed: true }
                { 'right-index: (if go-left middle-index right-index)
                , 'right-observation: (if go-left middle-observation right-observation)
                , 'left-index: (if go-left left-index middle-index)
                , 'left-observation: (if go-left left-observation middle-observation)
                , 'oracle: oracle
                , 'time: query-time
                , 'found: (= 1 (abs (- left-index middle-index)))
                , 'failed: false }
              ))))
      )
    )
  )

  (defun search-for-observation:object{observation}
    ( pair-key:string
      target:time
    )
    (let*
      ( (oracle (read oracles pair-key))
        (observation-capacity (at 'observation-capacity oracle))
        (observed (at 'observations-made oracle))
        (other-bound (if (>= observed observation-capacity) (- 1 observation-capacity) (- 0 observed)))
        (result (fold (short-circuit-query)
          { 'found: false
          , 'failed: false
          , 'time: target
          , 'oracle: oracle
          , 'right-index: other-bound
          , 'left-index: 0
          , 'right-observation: (try-get-observation oracle other-bound)
          , 'left-observation: (try-get-observation oracle 0) }
          (enumerate (+ 1 (log 2 observation-capacity)) 0)))
      )
      (if (at 'found result)
        { 'left-observation: (at 'left-observation result), 'right-observation: (at 'right-observation result) }
        {})
    )
  )

  (defun adjust
    ( observation-pair
      quote-leg0:bool
      target-time:time
    )
    (bind (at 'left-observation observation-pair) { 'timestamp := time-start, (if quote-leg0 'price0 'price1) := price-start }
      (bind (at 'right-observation observation-pair) { 'timestamp := time-end, (if quote-leg0 'price0 'price1) := price-end }
        (if (= target-time time-start)
          { 'cumulative-price: price-start
          , 'timestamp: time-start }
          (if (= target-time time-end)
            { 'cumulative-price: price-end
            , 'timestamp: time-end }
            (let*
              ( (price-span (- price-end price-start))
                (time-span (diff-time time-end time-start))
                (adjustment-ratio (/ (diff-time target-time time-start) time-span))
                (price-adjustment-from-start (* price-span adjustment-ratio))
              )
              { 'cumulative-price: (+ price-start price-adjustment-from-start)
              , 'timestamp: target-time }
            )
          )
        )
      )
    )
  )

  (defun linear-estimate-price:decimal
    ( pair-key:string
      quote-leg0:bool
      start:time
      end:time
    )
    (let*
      ( (start-observation-pair (linear-search-for-observation pair-key start))
        (end-observation-pair (linear-search-for-observation pair-key end))
      )
      (enforce (!= {} start-observation-pair) "Did not find start observation")
      (enforce (!= {} end-observation-pair) "Did not find end observation")
      (let*
        ( (start-adjusted (adjust start-observation-pair quote-leg0 start))
          (end-adjusted (adjust end-observation-pair quote-leg0 end))
          (price-difference (- (at 'cumulative-price end-adjusted) (at 'cumulative-price start-adjusted)))
          (time-difference (diff-time (at 'timestamp end-adjusted) (at 'timestamp start-adjusted)))
        )
        (round (/ price-difference time-difference) 8))
    )
  )

  (defun estimate-price:decimal
    ( pair-key:string
      quote-leg0:bool
      start:time
      end:time
    )
    (let*
      ( (start-observation-pair (search-for-observation pair-key start))
        (end-observation-pair (search-for-observation pair-key end))
      )
      (enforce (!= {} start-observation-pair) "Did not find start observation")
      (enforce (!= {} end-observation-pair) "Did not find end observation")
      (let*
        ( (start-adjusted (adjust start-observation-pair quote-leg0 start))
          (end-adjusted (adjust end-observation-pair quote-leg0 end))
          (price-difference (- (at 'cumulative-price end-adjusted) (at 'cumulative-price start-adjusted)))
          (time-difference (diff-time (at 'timestamp end-adjusted) (at 'timestamp start-adjusted)))
        )
        (round (/ price-difference time-difference) 8))
    )
  )

  (defun observation-in-range:bool
    ( observation0:object
      observation1:object
      target:time
    )
    (if (or (= observation0 {}) (= observation1 {})) false
      (let*
        ( (timestamp0 (at 'timestamp observation0))
          (timestamp1 (at 'timestamp observation1))
          (start-timestamp (if (< timestamp0 timestamp1) timestamp0 timestamp1))
          (end-timestamp (if (< timestamp0 timestamp1) timestamp1 timestamp0))
        )
        (if
          (or (= start-timestamp EPOCH_ZERO)
              (<= end-timestamp start-timestamp))
              false ;; either we've wrapped around or reached an uninitialized observation
          (and (<= start-timestamp target) (<= target end-timestamp)))))
  )

  (defun observe:object{observation}
    ( oracle:object{oracle}
      pair-key:string
    )
    (require-capability (OBSERVING))
    (let*
      ( (pair (read pairs pair-key))
        (leg0 (at 'leg0 pair))
        (leg1 (at 'leg1 pair))
        (last-observed (at 'last-observed oracle))
        (last-cumulative-price0 (at 'cumulative-price0 oracle))
        (last-cumulative-price1 (at 'cumulative-price1 oracle))
        (block-time (at 'block-time (chain-data)))
        (time-delta (diff-time block-time last-observed))
        (reserve0 (at 'reserve leg0))
        (reserve1 (at 'reserve leg1))
        (price0 (try 0.0 (/ reserve0 reserve1)))
        (price1 (try 0.0 (/ reserve1 reserve0)))
        (cumulative-price0 (round (+ last-cumulative-price0 (* time-delta price0)) 8))
        (cumulative-price1 (round (+ last-cumulative-price1 (* time-delta price1)) 8))
      )
      { 'timestamp: block-time
      , 'price0: cumulative-price0
      , 'price1: cumulative-price1 }
    )
  )

  (defun maybe-observe:bool
    ( pair-key:string
    )
    (require-capability (OBSERVING))
    (with-default-read oracles pair-key
      { 'observations-made: -1 }
      { 'observations-made := observations-made }
      (if (= observations-made -1)
        (write oracles pair-key
          { 'pair-key: pair-key
          , 'observations-made: 0
          , 'observation-capacity: 1
          , 'cumulative-price0: 0.0
          , 'cumulative-price1: 0.0
          , 'last-observed: (at 'block-time (chain-data)) }
        ) "")
      (let*
        ( (chain-data (chain-data))
          (block-time (at 'block-time chain-data))
          (oracle (read oracles pair-key))
          (last-observed (at 'last-observed oracle))
        )
        (if (and (!= observations-made -1) (<= block-time last-observed)) false
          (let*
            ( (new-observation (observe oracle pair-key))
              (target-key (get-observation-key oracle 1))
              (cumulative-price0 (at 'price0 new-observation))
              (cumulative-price1 (at 'price1 new-observation))
            )
            (write observations target-key new-observation)
            (update oracles pair-key
              { 'observations-made: (+ 1 (at 'observations-made oracle))
              , 'cumulative-price0: cumulative-price0
              , 'cumulative-price1: cumulative-price1
              , 'last-observed: block-time })
            true
          )
        )
      )
    )
  )

  (defun get-pair:object{pair}
    ( tokenA:module{fungible-v2}
      tokenB:module{fungible-v2}
    )
    (read pairs (get-pair-key tokenA tokenB)))

  (defun pair-exists:bool
    ( tokenA:module{fungible-v2}
      tokenB:module{fungible-v2}
    )
    (with-default-read pairs
      (get-pair-key tokenA tokenB)
      { 'account: "" }
      { 'account := a }
      (> (length a) 0))
  )

  (defun update-reserves
    ( p:object{pair}
      pair-key:string
      reserve0:decimal
      reserve1:decimal
    )
    (require-capability (UPDATING))
    (with-capability (OBSERVING)
      (maybe-observe pair-key)
    )
    (with-capability (UPDATE pair-key reserve0 reserve1)
      (update pairs pair-key
        { 'leg0: { 'token: (at 'token (at 'leg0 p))
                 , 'reserve: reserve0 }
        , 'leg1: { 'token: (at 'token (at 'leg1 p))
                 , 'reserve: reserve1 }}))
  )

  (defun add-liquidity:object
    ( tokenA:module{fungible-v2}
      tokenB:module{fungible-v2}
      amountADesired:decimal
      amountBDesired:decimal
      amountAMin:decimal
      amountBMin:decimal
      sender:string
      to:string
      to-guard:guard
    )
    (tokenA::enforce-unit amountADesired)
    (tokenB::enforce-unit amountBDesired)
    (let*
      ( (p (get-pair tokenA tokenB))
        (reserveA (reserve-for p tokenA))
        (reserveB (reserve-for p tokenB))
        (amounts
          (if (and (= reserveA 0.0) (= reserveB 0.0))
            [amountADesired amountBDesired]
            (let ((amountBOptimal (quote amountADesired reserveA reserveB)))
              (if (<= amountBOptimal amountBDesired)
                (let ((x (enforce (>= amountBOptimal amountBMin)
                           "add-liquidity: insufficient B amount")))
                  [amountADesired amountBOptimal])
                (let ((amountAOptimal (quote amountBDesired reserveB reserveA)))
                  (enforce (<= amountAOptimal amountADesired)
                    "add-liquidity: optimal A less than desired")
                  (enforce (>= amountAOptimal amountAMin)
                    "add-liquidity: insufficient A amount")
                  [amountAOptimal amountBDesired])))))
        (amountA (truncate tokenA (at 0 amounts)))
        (amountB (truncate tokenB (at 1 amounts)))
        (pair-account (at 'account p))
      )
      ;; transfer
      (tokenA::transfer sender pair-account amountA)
      (tokenB::transfer sender pair-account amountB)
      ;; mint
      (let*
        ( (token0:module{fungible-v2} (at 'token (at 'leg0 p)))
          (token1:module{fungible-v2} (at 'token (at 'leg1 p)))
          (balance0 (token0::get-balance pair-account))
          (balance1 (token1::get-balance pair-account))
          (reserve0 (at 'reserve (at 'leg0 p)))
          (reserve1 (at 'reserve (at 'leg1 p)))
          (amount0 (- balance0 reserve0))
          (amount1 (- balance1 reserve1))
          (key (get-pair-key tokenA tokenB))
          (totalSupply (tokens.total-supply key))
          (liquidity (tokens.truncate key
            (if (= totalSupply 0.0)
              (with-capability (ISSUING)
                (mint key LOCK_ACCOUNT (at 'guard p) MINIMUM_LIQUIDITY)
                (- (sqrt (* amount0 amount1)) MINIMUM_LIQUIDITY))
              (let ((l0 (/ (* amount0 totalSupply) reserve0))
                    (l1 (/ (* amount1 totalSupply) reserve1))
                   )
                ;; need min, max
                (if (<= l0 l1) l0 l1)))))
        )
        (enforce (> liquidity 0.0) "mint: insufficient liquidity minted")
        (with-capability (ISSUING)
          (mint key to to-guard liquidity))
        (with-capability (UPDATING)
          (update-reserves p key balance0 balance1))
        { "liquidity": liquidity
        , "supply": (tokens.total-supply key)
        , "amount0": amount0
        , "amount1": amount1
        }
      )
    )
  )

  (defun mint (token:string to:string guard:guard amount:decimal)
    (require-capability (ISSUING))
    (install-capability (tokens.MINT token to amount))
    (tokens.mint token to guard amount)
  )

  (defun quote
    ( amountA:decimal
      reserveA:decimal
      reserveB:decimal
    )
    (enforce (> amountA 0.0) "quote: insufficient amount")
    (enforce (and (> reserveA 0.0) (> reserveB 0.0)) "quote: insufficient liquidity")
    (/ (* amountA reserveB) reserveA)
  )


  (defun remove-liquidity:object
    ( tokenA:module{fungible-v2}
      tokenB:module{fungible-v2}
      liquidity:decimal
      amountAMin:decimal
      amountBMin:decimal
      sender:string
      to:string
      to-guard:guard
    )
    (let* ( (p (get-pair tokenA tokenB))
            (pair-account (at 'account p))
            (pair-key (get-pair-key tokenA tokenB))
          )
      (tokens.transfer pair-key sender pair-account liquidity)
      (let*
        ( (token0:module{fungible-v2} (at 'token (at 'leg0 p)))
          (token1:module{fungible-v2} (at 'token (at 'leg1 p)))
          (balance0 (token0::get-balance pair-account))
          (balance1 (token1::get-balance pair-account))
          (liquidity_ (tokens.get-balance pair-key pair-account))
          (total-supply (tokens.total-supply pair-key))
          (amount0 (truncate token0 (/ (* liquidity_ balance0) total-supply)))
          (amount1 (truncate token1 (/ (* liquidity_ balance1) total-supply)))
          (canon (is-canonical tokenA tokenB))
        )
        (enforce (and (> amount0 0.0) (> amount1 0.0))
          "remove-liquidity: insufficient liquidity burned")
        (enforce (>= (if canon amount0 amount1) amountAMin)
          "remove-liquidity: insufficient A amount")
        (enforce (>= (if canon amount1 amount0) amountBMin)
          "remove-liquidity: insufficient B amount")
        (with-capability (ISSUING)
          (burn pair-key pair-account liquidity))
        (install-capability (token0::TRANSFER pair-account to amount0))
        (token0::transfer-create pair-account to to-guard amount0)
        (install-capability (token1::TRANSFER pair-account to amount1))
        (token1::transfer-create pair-account to to-guard amount1)
        (with-capability (UPDATING)
          (update-reserves p pair-key
            (token0::get-balance pair-account)
            (token1::get-balance pair-account)))
        { 'amount0: amount0
        , 'amount1: amount1
        }
      )
    )
  )

  (defun burn (token:string to:string amount:decimal)
    (require-capability (ISSUING))
    (install-capability (tokens.BURN token to amount))
    (tokens.burn token to amount)
  )

  (defschema alloc
    token-out:module{fungible-v2}
    token-in:module{fungible-v2}
    out:decimal
    in:decimal
    idx:integer
    pair:object{pair}
    path:[module{fungible-v2}]
  )

  (defun swap-exact-in
    ( amountIn:decimal
      amountOutMin:decimal
      path:[module{fungible-v2}]
      sender:string
      to:string
      to-guard:guard
    )
    (enforce (>= (length path) 2) "swap-exact-in: invalid path")
    ;; fold over tail of path with dummy first value to compute outputs
    ;; assembles allocs in reverse
    (let*
      ( (p0 (get-pair (at 0 path) (at 1 path)))
        (allocs
          (fold (compute-out)
            [ { 'token-out: (at 0 path)
              , 'token-in: (at 1 path)
              , 'out: amountIn
              , 'in: 0.0
              , 'idx: 0
              , 'pair: p0
              , 'path: path
              }]
            (drop 1 path)))
      )
      (enforce (>= (at 'out (at 0 allocs)) amountOutMin)
        "swap-exact-in: insufficient output amount")
      ;; initial dummy is correct for initial transfer
      (with-capability (SWAPPING)
        (swap-pair sender to to-guard (reverse allocs)))
    )
  )

  (defconst FEE 0.003)

  (defun compute-out
    ( allocs:[object{alloc}]
      token-out:module{fungible-v2}
    )
    (let*
      ( (head:object{alloc} (at 0 allocs))
        (token-in:module{fungible-v2} (at 'token-out head))
        (amountIn:decimal (at 'out head))
        (p (get-pair token-in token-out))
        (reserveIn (reserve-for p token-in))
        (reserveOut (reserve-for p token-out))
        (amountInWithFee (* (- 1.0 FEE) amountIn))
        (numerator (* amountInWithFee reserveOut))
        (denominator (+ reserveIn amountInWithFee))
      )
      (+ [ { 'token-out: token-out
           , 'token-in: token-in
           , 'in: amountIn
           , 'out: (truncate token-out (/ numerator denominator))
           , 'idx: (+ 1 (at 'idx head))
           , 'pair: p
           , 'path: (drop 1 (at 'path head))
           } ]
         allocs)
    )
  )


  (defun swap-exact-out
    ( amountOut:decimal
      amountInMax:decimal
      path:[module{fungible-v2}]
      sender:string
      to:string
      to-guard:guard
    )
    (enforce (>= (length path) 2) "swap-exact-out: invalid path")
    ;; fold over tail of reverse path with dummy first value to compute inputs
    ;; assembles allocs in forward order
    (let*
      ( (rpath (reverse path))
        (path-len (length path))
        (pz (get-pair (at 0 rpath) (at 1 rpath)))
        (e:[module{fungible-v2}] [])
        (allocs
          (fold (compute-in)
            [ { 'token-out: (at 1 rpath)
              , 'token-in: (at 0 rpath)
              , 'out: 0.0
              , 'in: amountOut
              , 'idx: path-len
              , 'pair: pz
              , 'path: e
              }]
            (drop 1 rpath)))
        (allocs1 ;; drop dummy at end, prepend dummy for initial transfer
          (+ [  { 'token-out: (at 0 path)
                , 'token-in: (at 1 path)
                , 'out: (at 'in (at 0 allocs))
                , 'in: 0.0
                , 'idx: 0
                , 'pair: (at 'pair (at 0 allocs))
                , 'path: path
             } ]
             (take (- path-len 1) allocs)))
      )
      (enforce (<= (at 'out (at 0 allocs1)) amountInMax)
        (format "swap-exact-out: excessive input amount {}"
          [(at 'out (at 0 allocs1))]))
      (with-capability (SWAPPING)
        (swap-pair sender to to-guard allocs1))
    )
  )

  (defun compute-in
    ( allocs:[object{alloc}]
      token-in:module{fungible-v2}
    )
    (let*
      ( (head:object{alloc} (at 0 allocs))
        (token-out:module{fungible-v2} (at 'token-in head))
        (amountOut:decimal (at 'in head))
        (p (get-pair token-in token-out))
        (reserveIn (reserve-for p token-in))
        (reserveOut (reserve-for p token-out))
        (numerator (* reserveIn amountOut))
        (denominator (* (- reserveOut amountOut) (- 1.0 FEE)))
      )
      (+ [ { 'token-out: token-out
           , 'token-in: token-in
           , 'in: (ceiling (/ numerator denominator) (token-in::precision))
           , 'out: amountOut
           , 'idx: (- (at 'idx head) 1)
           , 'pair: p
           , 'path: (+ [token-out] (at 'path head))
           } ]
         allocs)
    )
  )



  (defun swap-pair
    ( sender:string
      to:string
      to-guard:guard
      allocs:[object{alloc}]
    )
    (require-capability (SWAPPING))
    (let*
      ( (head:object{alloc} (at 0 allocs))
        (head-token:module{fungible-v2} (at 'token-out head))
        (account (at 'account (at 'pair head)))
        (out (at 'out head))
      )
      (head-token::transfer sender account out)
      (+ [ { 'token: (format "{}" [head-token])
           , 'amount: out } ]
        (map
          (swap-alloc
            (- (length allocs) 1)
            to
            to-guard)
          (drop 1 allocs)))
    )
  )

  (defun swap-alloc
    ( last:integer
      to:string
      guard:guard
      alloc:object{alloc}
    )
    (require-capability (SWAPPING))
    (let*
      ( (path (at 'path alloc))
        (is-last (= last (at 'idx alloc)))
        (next-pair
          (if is-last (at 'pair alloc) (get-pair (at 0 path) (at 1 path))))
        (recipient
          (if is-last to (at 'account next-pair)))
        (recip-guard
          (if is-last guard (at 'guard next-pair)))
      )
      (swap noop-callable recipient recip-guard
        (at 'token-out alloc)
        (at 'out alloc)
        (at 'token-in alloc)))
  )

  (defun swap
    ( callable:module{swap-callable-v1}
      recipient:string
      recip-guard:guard
      token:module{fungible-v2}
      amount-out:decimal
      token-in:module{fungible-v2}
    )
    " Swap AMOUNT-OUT of TOKEN to RECIPIENT/RECIP-GUARD, \
    \ such that a corresponding transfer to TOKEN-IN, either \
    \ previously or during the execution of 'CALLABLE::swap-call', \
    \ will satisfy the constant-product invariant for the pair."
    (let*
      ( (p (get-pair token token-in))
        (account (at 'account p))
        (reserve-out (reserve-for p token))
      )
      (enforce (> amount-out 0.0) "swap: insufficient output")
      (enforce (< amount-out reserve-out) "swap: insufficient liquidity")
      (enforce (!= recipient account) "swap: invalid TO")
      ;;fire swap event
      (install-capability (token::TRANSFER account recipient amount-out))
      (token::transfer-create account recipient recip-guard amount-out)

      (callable::swap-call token-in token amount-out
        account recipient recip-guard)

      (let*
        ( (leg0 (at 'leg0 p))
          (leg1 (at 'leg1 p))
          (token0:module{fungible-v2} (at 'token leg0))
          (token1:module{fungible-v2} (at 'token leg1))
          (balance0 (token0::get-balance account))
          (balance1 (token1::get-balance account))
          (reserve0 (at 'reserve leg0))
          (reserve1 (at 'reserve leg1))
          (canon (is-leg0 p token))
          (amount0Out (if canon amount-out 0.0))
          (amount1Out (if canon 0.0 amount-out))
          (amount0In (if (> balance0 (- reserve0 amount0Out))
                        (- balance0 (- reserve0 amount0Out))
                        0.0))
          (amount1In (if (> balance1 (- reserve1 amount1Out))
                        (- balance1 (- reserve1 amount1Out))
                        0.0))
          (balance0adjusted (- balance0 (* amount0In 0.003)))
          (balance1adjusted (- balance1 (* amount1In 0.003)))
        )
        (enforce (or (> amount0In 0.0) (> amount1In 0.0))
          "swap: insufficient input amount")
        (enforce (>= (* balance0adjusted balance1adjusted)
                     (* reserve0 reserve1))
          (format "swap: K ({} < {})"
          [(* balance0adjusted balance1adjusted) (* reserve0 reserve1)]))
        (with-capability (UPDATING)
          (with-capability
            (SWAP account recipient
              (if canon amount1In amount0In)
              token-in amount-out token)
            (update-reserves p
              (get-pair-key token0 token1) balance0 balance1)))
        { 'token: (format "{}" [token])
        , 'amount: amount-out
        }
      )
    )
  )

  (defun create-pair:object{pair}
    ( token0:module{fungible-v2}
      token1:module{fungible-v2}
      hint:string
      )
    " Create new pair for legs TOKEN0 and TOKEN1. This creates a new \
    \ pair record, a liquidity token named after the canonical pair key \
    \ in 'swap.tokens' module, and new empty accounts in each leg token. \
    \ If account key value is already taken in leg tokens, transaction \
    \ will fail, which is why HINT exists (which should normally be \"\"), \
    \ to further seed the hash function creating the account id."
    (let* ((key (get-pair-key token0 token1))
           (canon (is-canonical token0 token1))
           (ctoken0 (if canon token0 token1))
           (ctoken1 (if canon token1 token0))
           (a (create-pair-account key hint))
           (g (create-module-guard key))
           (p { 'leg0: { 'token: ctoken0, 'reserve: 0.0 }
              , 'leg1: { 'token: ctoken1, 'reserve: 0.0 }
              , 'account: a
              , 'guard: g
              })
           )
      (with-capability (CREATE_PAIR ctoken0 ctoken1 key a)
        (insert pairs key p)
        (token0::create-account a g)
        (token1::create-account a g)
        (tokens.create-account key a g)
        { "key": key
        , "account": a
        }))
    )

  (defun get-pair-key:string
    ( tokenA:module{fungible-v2}
      tokenB:module{fungible-v2}
    )
    " Create canonical key for pair."
    (format "{}:{}" (canonicalize tokenA tokenB))
  )

  (defun canonicalize:[module{fungible-v2}]
    ( tokenA:module{fungible-v2}
      tokenB:module{fungible-v2}
    )
    (if (is-canonical tokenA tokenB) [tokenA tokenB] [tokenB tokenA])
  )

  (defun is-canonical
    ( tokenA:module{fungible-v2}
      tokenB:module{fungible-v2}
    )
    (< (format "{}" [tokenA]) (format "{}" [tokenB]))
  )

  (defun is-leg0:bool
    ( p:object{pair}
      token:module{fungible-v2}
    )
    (let ((token0 (at 'token (at 'leg0 p))))
      (= (format "{}" [token])
         (format "{}" [token0]))) ;; TODO modref equality
  )

  (defun leg-for:object{leg}
    ( p:object{pair}
      token:module{fungible-v2}
    )
    (if (is-leg0 p token)
      (at 'leg0 p)
      (at 'leg1 p))
  )

  (defun reserve-for:decimal
    ( p:object{pair}
      token:module{fungible-v2}
    )
    (at 'reserve (leg-for p token))
  )

  (defun create-pair-account:string
    ( key:string hint:string)
    (hash (+ hint (+ key (format "{}" [(at 'block-time (chain-data))]))))
  )

  (defun truncate:decimal (token:module{fungible-v2} amount:decimal)
    (floor amount (token::precision))
  )



)
(if (read-msg 'upgrade)
  ["upgrade"]
  [ (create-table pairs)
    (create-table observations)
    (create-table oracles)
    (init)
  ]
)
