solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IUniswapV3Router.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

contract EnhancedArbitrage {
    address public owner; // Владелец контракта
    IUniswapV2Router02 public immutable uniswapV2Router; // Адрес маршрутизатора Uniswap V2
    IUniswapV3Router public immutable uniswapV3Router; // Адрес маршрутизатора Uniswap V3

    uint256 public constant SLIPPAGE_PERCENTAGE = 2; // Процент проскальзывания
    uint256 public constant GAS_COST = 21000; // Оценочная стоимость газа

    event ArbitrageOpportunity(address tokenA, address tokenB, uint256 profit); // Событие для возможности арбитража

    modifier onlyOwner() {
        require(msg.sender == owner, "Не владелец контракта");
        _;
    }

    modifier nonReentrant() {
        require(!reentrancyLock, "Повторный вызов");
        reentrancyLock = true;
        _;
        reentrancyLock = false;
    }

    bool private reentrancyLock = false; // Блокировка повторного вызова

    // Конструктор контракта
    constructor(address _uniswapV2Router, address _uniswapV3Router) {
        owner = msg.sender;
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
    }

    // Функция для выполнения арбитража
    function executeArbitrage(address tokenA, address tokenB, uint256 amount) external onlyOwner nonReentrant {
        (uint256 priceV2, uint256 priceV3, uint256 liquidityV2, uint256 liquidityV3) = getPricesAndLiquidity(tokenA, tokenB);
        
        require(liquidityV2 >= amount && liquidityV3 >= amount, "Недостаточно ликвидности");

        uint256 fees = calculateFees(amount);
        uint256 profitV2toV3 = (priceV3 > priceV2) ? (priceV3 - priceV2 - fees) : 0;
        uint256 profitV3toV2 = (priceV2 > priceV3) ? (priceV2 - priceV3 - fees) : 0;

        if (profitV2toV3 > 0) {
            buyOnV2(tokenA, tokenB, amount);
            sellOnV3(tokenB, tokenA, amount);
        } else if (profitV3toV2 > 0) {
            buyOnV3(tokenA, tokenB, amount);
            sellOnV2(tokenB, tokenA, amount);
        }
    }

    // Анализ возможности арбитража
    function analyzeArbitrageOpportunity(address tokenA, address tokenB) external view returns (bool, uint256) {
        (uint256 priceV2, uint256 priceV3, uint256 liquidityV2, uint256 liquidityV3) = getPricesAndLiquidity(tokenA, tokenB);
        
        uint256 fees = calculateFees(1e18); // Оценка сборов для одной единицы токена
        uint256 profitV2toV3 = (priceV3 > priceV2) ? (priceV3 - priceV2 - fees) : 0;
        uint256 profitV3toV2 = (priceV2 > priceV3) ? (priceV2 - priceV3 - fees) : 0;

        if (profitV2toV3 > 0 || profitV3toV2 > 0) {
            emit ArbitrageOpportunity(tokenA, tokenB, profitV2toV3 > profitV3toV2 ? profitV2toV3 : profitV3toV2);
            return (true, profitV2toV3 > profitV3toV2 ? profitV2toV3 : profitV3toV2);
        }

        return (false, 0); // Нет возможностей для арбитража
    }

    // Получение цен и ликвидности
    function getPricesAndLiquidity(address tokenA, address tokenB) internal view returns (uint256 priceV2, uint256 priceV3, uint256 liquidityV2, uint256 liquidityV3) {
        priceV2 = getPriceV2(tokenA, tokenB);
        priceV3 = getPriceV3(tokenA, tokenB);
        liquidityV2 = getLiquidityV2(tokenA, tokenB);
        liquidityV3 = getLiquidityV3(tokenA, tokenB);
    }

    // Получение цены из Uniswap V2
    function getPriceV2(address tokenA, address tokenB) internal view returns (uint256) {
        address pair = IUniswapV2Factory(uniswapV2Router.factory()).getPair(tokenA, tokenB);
        require(pair != address(0), "Пул не найден");
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        return (reserve1 * 1e18) / reserve0; // Цена с 18 десятичными знаками
    }

    // Получение ликвидности из Uniswap V2
    function getLiquidityV2(address tokenA, address tokenB) internal view returns (uint256) {
        address pair = IUniswapV2Factory(uniswapV2Router.factory()).getPair(tokenA, tokenB);
        require(pair != address(0), "Пул не найден");
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        return reserve0 + reserve1; // Общая ликвидность
    }

    // Получение цены из Uniswap V3
    function getPriceV3(address tokenA, address tokenB) internal view returns (uint256) {
        address pool = getPoolForV3(tokenA, tokenB, 3000); // 0.3% комиссия
        (uint160 sqrtPriceX96,,,) = IUniswapV3Pool(pool).slot0();
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) / (1 << 192); // Преобразование из sqrtPrice
    }

    // Получение ликвидности из Uniswap V3
    function getLiquidityV3(address tokenA, address tokenB) internal view returns (uint256 totalLiquidity) {
        address pool = getPoolForV3(tokenA, tokenB, 3000);
        // Здесь должна быть логика получения ликвидности, например, через позиции
        return /* реализуйте логику получения ликвидности на основе активных позиций */;
    }

    // Получение адреса пула для Uniswap V3
    function getPoolForV3(address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        return IUniswapV3Factory(uniswapV3Router.factory()).getPool(tokenA, tokenB, fee); // Получаем пул для указанных токенов
    }

    // Расчет сборов
    function calculateFees(uint256 amount) internal view returns (uint256) {
        uint256 gasCost = GAS_COST * tx.gasprice; // Оценочная стоимость газа
        uint256 slippage = (amount * SLIPPAGE_PERCENTAGE) / 100; // Оценка проскальзывания
        return gasCost + slippage; // Общая сумма сборов
    }

    // Покупка токена на Uniswap V2
    function buyOnV2(address tokenA, address tokenB, uint256 amount) internal {
        IERC20(tokenA).approve(address(uniswapV2Router), amount);
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    // Продажа токена на Uniswap V2
    function sellOnV2(address tokenA, address tokenB, uint256 amount) internal {
        IERC20(tokenA).approve(address(uniswapV2Router), amount);
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    // Покупка токена на Uniswap V3
    function buyOnV3(address tokenA, address tokenB, uint256 amount) internal {
        IERC20(tokenA).approve(address(uniswapV3Router), amount);
        uniswapV3Router.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenA,
            tokenOut: tokenB,
            fee: 3000, // 0.3% комиссия
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        }));
    }

    // Продажа токена на Uniswap V3
    function sellOnV3(address tokenA, address tokenB, uint256 amount) internal {
        IERC20(tokenA).approve(address(uniswapV3Router), amount);
        uniswapV3Router.exactInputSingle(IUniswapV3Router.ExactInputSingleParams({
            tokenIn: tokenA,
            tokenOut: tokenB,
            fee: 3000, // 0.3% комиссия
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        }));
    }
}

И после последнего обновления он сделал так , там в конце кода написанно остальные функции как и в предыдущем примере, он выше, как их объединить, я не знаю 

solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IUniswapV3Router.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@chainlink/contracts/src/interfaces/AggregatorV3Interface.sol";

contract EnhancedArbitrage {
    address public owner;
    IUniswapV2Router02 public immutable uniswapV2Router;
    IUniswapV3Router public immutable uniswapV3Router;
    AggregatorV3Interface internal priceFeed;

    uint256 public constant SLIPPAGE_PERCENTAGE = 2;
    uint256 public constant GAS_COST = 21000;

    event ArbitrageOpportunity(address[] tokenPath, uint256 profit);

    modifier onlyOwner() {
        require(msg.sender == owner, "Не владелец контракта");
        _;
    }

    modifier nonReentrant() {
        require(!reentrancyLock, "Повторный вызов");
        reentrancyLock = true;
        _;
        reentrancyLock = false;
    }

    bool private reentrancyLock = false;

    constructor(address _uniswapV2Router, address _uniswapV3Router, address _priceFeed) {
        owner = msg.sender;
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    function executeArbitrage(address[] calldata tokenPath, uint256 amount) external onlyOwner nonReentrant {
        require(tokenPath.length >= 2, "Минимум 2 токена для арбитража");

        uint256 fees = calculateFees(amount, true);
        uint256 amountIn = amount - fees; // Учитываем сборы

        for (uint256 i = 0; i < tokenPath.length - 1; i++) {
            buyOnToken(tokenPath[i], tokenPath[i + 1], amountIn);
            amountIn = IERC20(tokenPath[i + 1]).balanceOf(address(this)); // Обновляем количество после покупки
        }

        uint256 profit = calculateProfit(tokenPath);
        emit ArbitrageOpportunity(tokenPath, profit);
    }

    function calculateProfit(address[] calldata tokenPath) internal view returns (uint256) {
        // Логика для расчета прибыли на основе текущих цен
        uint256 finalBalance = IERC20(tokenPath[tokenPath.length - 1]).balanceOf(address(this));
        return finalBalance; // В данном случае просто возвращаем баланс, можно добавить логику
    }

    function minimizeSlippage(uint256 amountIn, uint256 priceOut) internal pure returns (uint256) {
        uint256 slippageAmount = (amountIn * SLIPPAGE_PERCENTAGE) / 100;
        return priceOut - slippageAmount; // Учитываем проскальзывание
    }

    function calculateFees(uint256 amount, bool isArbitrage) internal view returns (uint256) {
        uint256 gasCost = GAS_COST * tx.gasprice;
        uint256 slippage = isArbitrage ? (amount * (SLIPPAGE_PERCENTAGE / 2)) / 100 : (amount * SLIPPAGE_PERCENTAGE) / 100; 
        return gasCost + slippage; 
    }

    function buyOnToken(address tokenA, address tokenB, uint256 amountIn) internal {
        IERC20(tokenA).approve(address(uniswapV2Router), amountIn);
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            address(this),
            block.timestamp
        );
    }
    
    // Добавьте функции для продаж на Uniswap V2 или V3
    function sellOnToken(address tokenA, address tokenB, uint256 amountIn) internal {
        // Логика продажи, аналогичная функции buyOnToken, измените пути и интерфейсы для реализации
    }

    // Остальные функции аналогичны предыдущему примеру...
}


### Усовершенствования и функции:
1. **Поддержка нескольких токенов** для арбитража через массив `tokenPath`, который позволяет выполнять операции с множеством токенов.
2. **Уменьшение проскальзывания:** Функция `minimizeSlippage` для учета проскальзывания в расчетах.
3. **Процент сборов:** Функция `calculateFees` для динамической оценки сборов на основе размера сделки и типа (арбитраж или обычная сделка).
4. **Агрегация сделок:** Метод `executeArbitrage` обрабатывает все операции в одной функции, что уменьшает количество транзакций и затраты на газ.
