solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Интерфейсы DEX
interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IBakeryRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IApeRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

// Основной контракт арбитража
contract ArbitrageContract is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPancakeRouter public pancakeRouter;
    IBakeryRouter public bakeryRouter;
    IApeRouter public apeRouter;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    event ArbitrageExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 profit, address indexed trader);
    event Withdrawal(address indexed token, uint256 amount);
    event ErrorOccurred(string message);

    constructor(address _pancakeRouter, address _bakeryRouter, address _apeRouter) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        pancakeRouter = IPancakeRouter(_pancakeRouter);
        bakeryRouter = IBakeryRouter(_bakeryRouter);
        apeRouter = IApeRouter(_apeRouter);
    }

    // Функция для оценки газа при выполнении арбитража
    function estimateGasForArbitrage(
        address[][] calldata paths,
        uint256 amountIn,
        uint256[] calldata minAmountsOut
    ) external view returns (uint256 estimatedGas) {
        // Примерный расчет газа, достаточно общей оценки
        uint256 baseGasCost = 21000; // базовая стоимость транзакции
        uint256 loopGasCost = 50000;  // средняя стоимость газа за каждую итерацию обмена

        estimatedGas = baseGasCost + (paths.length * loopGasCost);
    }

    // Обновленная функция для оценки прибыли с учетом газа
    function estimateProfitWithGas(address[] calldata path, uint256 amountIn) external view returns (uint256 expectedAmountOut, uint256 gasCost) {
        uint256 estimatedGas = estimateGasForArbitrage(path, amountIn, new uint256[](0));
        gasCost = estimatedGas * tx.gasprice; // Рассчитываем потенциальные затраты на газ

        // Получаем выходные значения для каждого DEX
        uint256[] memory amountsOut = pancakeRouter.getAmountsOut(amountIn, path);
        expectedAmountOut = amountsOut[amountsOut.length - 1];

        // Продолжаем аналогично для остальных DEX
        amountsOut = bakeryRouter.getAmountsOut(amountIn, path);
        expectedAmountOut = expectedAmountOut > amountsOut[amountsOut.length - 1] ? expectedAmountOut : amountsOut[amountsOut.length - 1];

        amountsOut = apeRouter.getAmountsOut(amountIn, path);
        expectedAmountOut = expectedAmountOut > amountsOut[amountsOut.length - 1] ? expectedAmountOut : amountsOut[amountsOut.length - 1];

        // Уменьшаем ожидаемую прибыль за счет газовых затрат
        expectedAmountOut -= gasCost;
    }

    // Функция для выполнения арбитража
    function executeArbitrage(
        address[][] calldata paths,
        uint256 amountIn,
        uint256[] calldata minAmountsOut
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(amountIn > 0, "Amount must be greater than 0");
        require(paths.length > 0, "No paths provided");

        uint256 currentAmountIn = amountIn;

        for (uint256 i = 0; i < paths.length; i++) {
            require(paths[i].length >= 2, "Invalid path length");
            require(paths[i][0] != address(0) && paths[i][1] != address(0), "Token address cannot be zero");

            // Получаем выходные значения для каждого DEX и проверяем прибыль
            uint256[] memory amountsOut;
            if (i % 3 == 0) {
                amountsOut = pancakeRouter.getAmountsOut(currentAmountIn, paths[i]);
            } else if (i % 3 == 1) {
                amountsOut = bakeryRouter.getAmountsOut(currentAmountIn, paths[i]);
            } else {
                amountsOut = apeRouter.getAmountsOut(currentAmountIn, paths[i]);
            }

            require(amountsOut[amountsOut.length - 1] >= minAmountsOut[i], "Insufficient output");

            // Выполняем обмен на соответствующем DEX
            IERC20(paths[i][0]).safeTransferFrom(msg.sender, address(this), currentAmountIn);
            IERC20(paths[i][0]).safeApprove(
                i % 3 == 0 ? address(pancakeRouter) : (i % 3 == 1 ? address(bakeryRouter) : address(apeRouter)),
                currentAmountIn
            );

            if (i % 3 == 0) {
                pancakeRouter.swapExactTokensForTokens(currentAmountIn, minAmountsOut[i], paths[i], address(this), block.timestamp);
            } else if (i % 3 == 1) {
                bakeryRouter.swapExactTokensForTokens(currentAmountIn, minAmountsOut[i], paths[i], address(this), block.timestamp);
            } else {
                apeRouter.swapExactTokensForTokens(currentAmountIn, minAmountsOut[i], paths[i], address(this), block.timestamp);
            }

            currentAmountIn = IERC20(paths[i][1]).balanceOf(address(this));
        }

        // Событие завершения арбитража
        emit ArbitrageExecuted(paths[0][0], paths[paths.length - 1][1], amountIn, currentAmountIn, msg.sender);
    }

    // Функция для вывода токенов
    function withdrawTokens(address token, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(amount <= getTokenBalance(token), "Insufficient balance");
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawal(token, amount);
    }

    // Функция для получения баланса токенов
    function getTokenBalance(address token) public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}


### Основные обновления и улучшения:

1. **Оценка газа**:
- Добавлена функция `estimateGasForArbitrage`, которая позволяет оценивать газовые затраты для выполнения арбитража, что дает возможность заранее оценить стоимость выполнения операций.

2. **Оценка прибыли с учетом газа**:
- Обновлена функция `estimateProfitWithGas`, которая возвращает ожидаемую прибыль после вычета вероятных расходов на газ.

3. **Улучшенная валидация**:
- В функции `executeArbitrage` добавлены проверки для предотвращения передачи токенов с недопустимыми адресами и дополнительная логика по индикации ошибок.

4. **Обратная связь пользователю**:
- Эмитирование событий после выполнения арбитража и вывода средств, что улучшает прозрачность работы контракта и позволяет отслеживать его действия.
